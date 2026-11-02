#!/usr/bin/env python3
"""Exercise the actual model event switch against a held owned Swift task."""
from pathlib import Path
import os
import subprocess
import tempfile

ROOT = Path(__file__).resolve().parents[2]
source = (ROOT / 'Desktop/Sources/ClipboardDesktop/HistoryModel.swift').read_text(encoding='utf-8')
start = source.index('switch event {', source.index('eventsTask = Task'))
opening = source.index('{', start)
end, depth = opening + 1, 1
while depth:
    depth += (source[end] == '{') - (source[end] == '}')
    end += 1
actual = source[start:end]
probe = r'''
import Foundation
struct Item { let id: UUID; let sensitive: Bool }
enum Event { case inserted(Item), updated(Item), deleted(UUID), evicted(UUID, String, Bool), cleared }
actor Gate {
  var continuation: CheckedContinuation<Void,Never>?
  var waiter: CheckedContinuation<Void,Never>?
  func hold() async { await withCheckedContinuation { continuation=$0;waiter?.resume();waiter=nil } }
  func started() async { if continuation == nil { await withCheckedContinuation { waiter=$0 } } }
  func release() { continuation?.resume();continuation=nil }
}
@MainActor final class Scheduler {
  var tasks: [UUID:Task<Bool,Never>] = [:]
  func cancel(id:UUID) { tasks[id]?.cancel() }
  func cancelAll() { for task in tasks.values { task.cancel() } }
}
@MainActor final class Progress { func remove(id:UUID) {}; func clear() {} }
@MainActor final class Fixture {
  let analysisScheduler = Scheduler()
  let analysisProgress = Progress()
  var revealReset = false
  func resetSensitivePreview() { revealReset = true }
  func receive(_ event: Event) { __ACTUAL_SWITCH__ }
}
@main struct Probe {
  @MainActor static func main() async {
    let model=Fixture(), id=UUID(), unrelated=UUID(), gate=Gate(), otherGate=Gate()
    let task=Task { await gate.hold(); return Task.isCancelled }
    let other=Task { await otherGate.hold(); return Task.isCancelled }
    model.analysisScheduler.tasks[id]=task; model.analysisScheduler.tasks[unrelated]=other
    await gate.started(); await otherGate.started()
    model.receive(.updated(Item(id:id,sensitive:true)))
    await gate.release(); await otherGate.release()
    let cancelled=await task.value, unrelatedCancelled=await other.value
    guard cancelled && !unrelatedCancelled else { fatalError("sensitive_update_did_not_cancel_only_its_owned_analysis") }
    let plainGate=Gate(), plainTask=Task { await plainGate.hold(); return Task.isCancelled }
    model.analysisScheduler.tasks[id]=plainTask
    await plainGate.started()
    model.receive(.updated(Item(id:id,sensitive:false)))
    await plainGate.release()
    precondition(await plainTask.value == false)
    print("Actual store-event switch cancels sensitive analysis, retaining ordinary and unrelated work")
  }
}
'''.replace('__ACTUAL_SWITCH__', actual)
# Swift precondition autoclosures are synchronous.
probe = probe.replace('precondition(await plainTask.value == false)', 'let plainCancelled=await plainTask.value; precondition(!plainCancelled)')
with tempfile.TemporaryDirectory(prefix='clipboard-sensitive-analysis-') as temporary:
    directory = Path(temporary)
    code = directory / 'main.swift'
    code.write_text(probe, encoding='utf-8')
    executable = directory / ('probe.exe' if os.name == 'nt' else 'probe')
    subprocess.run(['swiftc','-parse-as-library','-swift-version','5','-module-cache-path',str(directory/'modules'),str(code),'-o',str(executable)],check=True,timeout=60)
    subprocess.run([str(executable)],check=True,timeout=10)
