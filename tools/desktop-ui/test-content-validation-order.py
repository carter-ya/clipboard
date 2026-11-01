#!/usr/bin/env python3
"""Exercise the actual content-save method while a preceding save is held."""
from pathlib import Path
import os
import shutil
import subprocess
import sys
import tempfile


root = Path(__file__).resolve().parents[2]
model = (root / 'Desktop/Sources/ClipboardDesktop/HistoryModel.swift').read_text(encoding='utf-8')
start = model.index('  @MainActor func applyContentSettings() async {')
end = model.index('\n  @MainActor func clearHistory', start)
method = model[start:end]
gate = (root / 'Core/Sources/ClipboardCore/Platform/DesktopSettingsSaveGate.swift').read_text(encoding='utf-8')
size_path = root / 'Core/Sources/ClipboardCore/Platform/DesktopSizeLimit.swift'
size = size_path.read_text(encoding='utf-8') if size_path.exists() else ''
fixture = r'''
import Foundation

@MainActor final class SubmissionSignal {
  private var ready = false
  private var waiter: CheckedContinuation<Void, Never>?
  func signal() {
    ready = true
    waiter?.resume()
    waiter = nil
  }
  func wait() async {
    if ready { return }
    await withCheckedContinuation { waiter = $0 }
  }
}

@MainActor final class ObservedGate {
  private let actual = DesktopSettingsSaveGate()
  private let submitted: SubmissionSignal
  private var requests = 0
  init(_ submitted: SubmissionSignal) { self.submitted = submitted }
  func acquire() async {
    requests += 1
    if requests == 2 { submitted.signal() }
    await actual.acquire()
  }
  func release() { actual.release() }
}

struct FixtureSettings: Sendable {
  var historyCapacity = 100
  var maxClipSizeBytes = 1024 * 1024
  var blockedAppIDs: [String] = []
  var blocklistEnabled = true
  var skipSensitive = true
  func validate() throws {}
}

actor HeldSettingsStore {
  private var entered = false
  private var pending: CheckedContinuation<Void, Never>?
  private var entryWaiters: [CheckedContinuation<Void, Never>] = []
  private var saved: FixtureSettings?
  private var saves = 0
  func save(_ settings: FixtureSettings) async throws {
    saves += 1
    await withCheckedContinuation { continuation in
      pending = continuation
      entered = true
      entryWaiters.forEach { $0.resume() }
      entryWaiters.removeAll()
    }
    saved = settings
  }
  func waitForSave() async {
    if entered { return }
    await withCheckedContinuation { entryWaiters.append($0) }
  }
  func release() { pending?.resume(); pending = nil }
  func snapshot() -> (Int, FixtureSettings?) { (saves, saved) }
}

@MainActor final class FixtureHistoryStore {
  func setCapacity(_ capacity: Int) async throws {}
}

@MainActor final class ModelFixture {
  let settingsStore: HeldSettingsStore?
  let store: FixtureHistoryStore? = FixtureHistoryStore()
  let settingsSaveGate: ObservedGate
  let submitted: SubmissionSignal
  var shuttingDown = false
  var capacityDraft = "100"
  var maxSizeDraft = "1"
  var blockedAppsDraft = ""
  var blocklistEnabledDraft = true
  var skipSensitiveDraft = true
  var recording = false
  var settings = FixtureSettings()
  var status = "Ready" {
    didSet {
      if status.hasPrefix("Enter a capacity") { submitted.signal() }
    }
  }
  init(_ saver: HeldSettingsStore, _ submitted: SubmissionSignal) {
    settingsStore = saver
    self.submitted = submitted
    settingsSaveGate = ObservedGate(submitted)
  }
  func setRecording(_ enabled: Bool) async { recording = enabled }
  func refresh() async {}
__ACTUAL_METHOD__
}

@main struct ValidationOrderRegression {
  @MainActor static func main() async {
    let submitted = SubmissionSignal()
    let saver = HeldSettingsStore()
    let model = ModelFixture(saver, submitted)
    let valid = Task { @MainActor in await model.applyContentSettings() }
    await saver.waitForSave()
    model.maxSizeDraft = "-1"
    let invalid = Task { @MainActor in await model.applyContentSettings() }
    // The second submission either reports an error immediately or reaches
    // the real FIFO gate. Both signals precede release of the first save.
    await submitted.wait()
    await saver.release()
    await valid.value
    await invalid.value
    guard model.status.hasPrefix("Enter a capacity") else {
      print("FAIL: preceding valid save overwrote the later validation error")
      return
    }
    let (saves, saved) = await saver.snapshot()
    guard saves == 1, saved?.maxClipSizeBytes == 1024 * 1024,
      model.settings.maxClipSizeBytes == 1024 * 1024, model.maxSizeDraft == "-1"
    else {
      print("FAIL: invalid submission changed persisted settings or the draft")
      return
    }
    print("PASS: actual content-save method retains the later error and prior valid settings")
  }
}
'''.replace('__ACTUAL_METHOD__', method)

compiler = shutil.which('swiftc')
if not compiler:
    raise RuntimeError('Swift compiler is required for the actual-method regression')
with tempfile.TemporaryDirectory(prefix='clipboard-content-validation-') as directory:
    folder = Path(directory)
    source = folder / 'ValidationOrder.swift'
    source.write_text(gate + '\n' + size + '\n' + fixture, encoding='utf-8')
    binary = folder / ('validation-order.exe' if os.name == 'nt' else 'validation-order')
    built = subprocess.run([compiler, '-parse-as-library', '-swift-version', '6',
                            '-module-cache-path', str(folder / 'module-cache'),
                            str(source), '-o', str(binary)], capture_output=True, text=True,
                           encoding='utf-8', errors='replace', timeout=60)
    if built.returncode:
        sys.stderr.write(built.stderr)
        raise SystemExit(1)
    result = subprocess.run([str(binary)], capture_output=True, text=True,
                            encoding='utf-8', errors='replace', timeout=10)
    sys.stdout.write(result.stdout)
    expected = 'PASS: actual content-save method retains the later error and prior valid settings'
    if result.returncode or result.stdout.strip() != expected:
        raise SystemExit(1)
