import ClipboardCore
import Foundation

#if os(Windows)
  import DesktopClipboard
  import CPlatformScenarioFixtures

  func runOwnedSourcePeer() -> Int32 { clipboard_run_owned_source_fixture() }

  /// Only the isolated Windows runner may publish this synthetic source fixture.
  func runPlatformSourceFilter() async -> Report {
    var checks: [CheckResult] = []
    guard ProcessInfo.processInfo.environment["CLIPBOARD_PRIVATE_SOURCE_TEST"] == "1" else {
      return .init(
        scenario: "platform-source-filter", passed: false,
        checks: [.init(name: "private_fixture_required", passed: false, detail: nil)])
    }
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + 30)
    watchdog.setEventHandler { exit(2) }
    watchdog.resume()
    defer { watchdog.cancel() }
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clipboard-source-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    var stage = "source_fixture_setup"
    do {
      guard let executable = Bundle.main.executableURL else { throw TextClipboardError.unavailable }
      try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false)
      let alias = root.appendingPathComponent("BiTwArDeN.exe")
      try FileManager.default.copyItem(at: executable, to: alias)
      let input = Pipe()
      let output = Pipe()
      let clipboard = try SystemRichClipboard()
      let peer = Process()
      peer.executableURL = alias
      peer.currentDirectoryURL = executable.deletingLastPathComponent()
      var environment = ProcessInfo.processInfo.environment
      let pathKey =
        environment.keys.first { $0.caseInsensitiveCompare("PATH") == .orderedSame } ?? "Path"
      environment[pathKey] =
        executable.deletingLastPathComponent().path + ";" + (environment[pathKey] ?? "")
      peer.environment = environment
      peer.arguments = ["source-clipboard-peer"]
      peer.standardInput = input
      peer.standardOutput = output
      peer.standardError = FileHandle.nullDevice
      stage = "source_fixture_peer_launch"
      try peer.run()
      defer {
        try? input.fileHandleForWriting.close()
        if peer.isRunning { peer.terminate() }
        peer.waitUntilExit()
      }
      stage = "source_fixture_peer_ready"
      var ready = Data()
      while ready.last != 10 {
        let byte = output.fileHandleForReading.readData(ofLength: 1)
        guard !byte.isEmpty, ready.count < 32 else { throw TextClipboardError.unavailable }
        ready.append(byte)
      }
      guard ready == Data("ready\n".utf8) else { throw TextClipboardError.unavailable }
      stage = "source_fixture_native_read"
      guard let snapshot = try clipboard.read(maxBytes: 1024 * 1024) else {
        stage = "source_fixture_empty_snapshot"
        throw TextClipboardError.unavailable
      }
      stage = "source_fixture_owner_identity"
      guard let source = snapshot.sourceAppID else { throw TextClipboardError.unavailable }
      check(
        "native_source_identifies_the_owned_synthetic_executable",
        source.lowercased() == "windows:bitwarden.exe", into: &checks)
      check("fixture_has_no_native_sensitive_hint", !snapshot.sensitive, into: &checks)
      var raw = RawClipItem(
        payloads: snapshot.payloads, bundleID: source,
        changeCount: Int(truncatingIfNeeded: snapshot.revision),
        totalBytes: snapshot.payloads.reduce(0) { $0 + $1.data.count })
      let context = ClipContext(
        sourceBundleID: source, changeCount: raw.changeCount, timestamp: raw.timestamp)
      let defaults = BlocklistFilter(blockedBundleIDs: DesktopSettings().blockedAppIDs)
      let defaultSensitive: Bool
      if case .markSensitive = defaults.evaluate(raw, context: context) {
        defaultSensitive = true
      } else {
        defaultSensitive = false
      }
      check("default_filter_marks_the_native_source_sensitive", defaultSensitive, into: &checks)
      let filter = BlocklistFilter(blockedBundleIDs: ["WINDOWS:BiTwArDeN.EXE"])
      if case .markSensitive(let reason) = filter.evaluate(raw, context: context) {
        raw.isSensitive = true
        raw.sensitivityReason = reason
      }
      check("custom_case_filter_marks_the_native_source_sensitive", raw.isSensitive, into: &checks)
      stage = "source_fixture_memory_store"
      let storeRoot = root.appendingPathComponent("store")
      let store = try await JSONSnapshotClipStore(root: storeRoot, inlineThresholdBytes: 1)
      await store.insert(raw)
      await store.flush()
      let live = await store.all()
      check(
        "source_filtered_item_remains_available_in_memory",
        live.count == 1 && live.first?.sensitive == true, into: &checks)
      let envelope =
        try JSONSerialization.jsonObject(
          with: Data(contentsOf: storeRoot.appendingPathComponent("history.json")))
        as? [String: Any]
      check(
        "source_filtered_item_is_absent_from_history",
        (envelope?["items"] as? [Any])?.isEmpty == true, into: &checks)
      let blobs = try FileManager.default.contentsOfDirectory(
        atPath: storeRoot.appendingPathComponent("blobs").path)
      check("source_filtered_payloads_never_create_blobs", blobs.isEmpty, into: &checks)
    } catch {
      check("native_source_filter_fixture", false, detail: stage, into: &checks)
    }
    return .init(
      scenario: "platform-source-filter", passed: !checks.isEmpty && checks.allSatisfy(\.passed),
      checks: checks)
  }
#else
  func runPlatformSourceFilter() async -> Report {
    .init(
      scenario: "platform-source-filter", passed: false,
      checks: [.init(name: "windows_fixture_required", passed: false, detail: nil)])
  }
#endif
