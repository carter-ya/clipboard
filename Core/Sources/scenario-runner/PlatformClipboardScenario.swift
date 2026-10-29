import ClipboardCore
import Foundation

#if os(Linux) || os(Windows)
  import DesktopClipboard
  private struct PeerCommand: Codable {
    let operation: String
    var text: String? = nil
    var sensitive: Bool? = nil
  }
  private struct PeerReply: Codable {
    var ok: Bool
    var text: String? = nil
    var sensitive: Bool? = nil
  }

  /// This child process owns a separate native clipboard connection. Its stdout
  /// is an IPC channel consumed by the scenario, never copied into test logs.
  func runClipboardPeer() throws {
    let clipboard = try SystemTextClipboard()
    while let line = readLine(), let data = line.data(using: .utf8) {
      let command = try JSONDecoder().decode(PeerCommand.self, from: data)
      var reply = PeerReply(ok: true)
      do {
        if command.operation == "write" {
          try clipboard.write(text: command.text ?? "", sensitive: command.sensitive ?? false)
        } else if command.operation == "read" {
          let snapshot = try clipboard.read(maxBytes: 1024 * 1024)
          reply.text = snapshot?.text
          reply.sensitive = snapshot?.sensitive
        } else {
          reply.ok = false
        }
      } catch { reply.ok = false }
      let encoded = try JSONEncoder().encode(reply)
      FileHandle.standardOutput.write(encoded + Data([10]))
    }
  }

  private final class ClipboardPeer {
    let process = Process()
    let input = Pipe()
    let output = Pipe()

    init() throws {
      process.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      process.arguments = ["clipboard-peer"]
      process.standardInput = input
      process.standardOutput = output
      try process.run()
    }

    func request(_ command: PeerCommand) throws -> PeerReply {
      let data = try JSONEncoder().encode(command)
      input.fileHandleForWriting.write(data + Data([10]))
      var line = Data()
      while true {
        let byte = output.fileHandleForReading.readData(ofLength: 1)
        guard !byte.isEmpty else { throw TextClipboardError.unavailable }
        if byte.first == 10 { break }
        line.append(byte)
        guard line.count <= 1024 * 1024 else { throw TextClipboardError.invalidText }
      }
      let reply = try JSONDecoder().decode(PeerReply.self, from: line)
      guard reply.ok else { throw TextClipboardError.unavailable }
      return reply
    }

    func close() {
      try? input.fileHandleForWriting.close()
      process.waitUntilExit()
      try? output.fileHandleForReading.close()
    }
  }

  private func nextValue<T: Sendable>(
    _ stream: AsyncStream<T>, action: () throws -> Void
  ) async throws -> T {
    try await withThrowingTaskGroup(of: T.self) { group in
      group.addTask {
        for await value in stream { return value }
        throw TextClipboardError.unavailable
      }
      group.addTask {
        try await Task.sleep(nanoseconds: 5_000_000_000)
        throw TextClipboardError.timeout
      }
      defer { group.cancelAll() }
      try action()
      guard let value = try await group.next() else { throw TextClipboardError.unavailable }
      return value
    }
  }

  func runPlatformClipboard() async -> Report {
    var checks: [CheckResult] = []
    // A hung peer or platform API cannot leave a runner waiting indefinitely.
    let watchdog = DispatchWorkItem { exit(2) }
    DispatchQueue.global().asyncAfter(deadline: .now() + 30, execute: watchdog)
    defer { watchdog.cancel() }
    var stage = "open"
    do {
      let clipboard = try SystemTextClipboard()
      try clipboard.write(text: "clipboard-test-seed")
      stage = "launch_peer"
      let peer = try ClipboardPeer()
      defer { peer.close() }
      let monitor = TextClipboardMonitor(clipboard: clipboard, maxBytes: 4096)
      monitor.start()
      defer { monitor.stop() }
      let fixture = "Clipboard native verification 😀 中文\nsecond line"
      stage = "capture_peer_write"
      let first = try await nextValue(monitor.changes) {
        _ = try peer.request(PeerCommand(operation: "write", text: fixture))
      }
      check(
        "peer_unicode_write_reaches_monitor",
        first.payloads.first?.data == Data(fixture.utf8), into: &checks)

      let updated = fixture + " updated"
      stage = "capture_same_owner_update"
      let second = try await nextValue(monitor.changes) {
        _ = try peer.request(PeerCommand(operation: "write", text: updated))
      }
      check(
        "same_owner_update_reaches_monitor",
        second.payloads.first?.data == Data(updated.utf8), into: &checks)

      let root = FileManager.default.temporaryDirectory
        .appendingPathComponent("clipboard-native-\(UUID().uuidString)")
      defer { try? FileManager.default.removeItem(at: root) }
      let store = try await JSONSnapshotClipStore(root: root, inlineThresholdBytes: 8)
      await store.insert(first)
      let selected = await store.all().first!
      try TextPasteboardWriter(clipboard: clipboard, blobRoot: root.appendingPathComponent("blobs"))
        .write(selected)
      stage = "independent_readback"
      let readBack = try peer.request(PeerCommand(operation: "read"))
      check("history_writer_reaches_independent_reader", readBack.text == fixture, into: &checks)

      // Drain the writer's ordinary change before waiting for the marked secret.
      let secret = "synthetic-sensitive-" + String(repeating: "s", count: 512)
      stage = "sensitive_native_hint"
      var secretRaw: RawClipItem?
      for _ in 0..<3 {
        let value = try await nextValue(monitor.changes) {
          _ = try peer.request(PeerCommand(operation: "write", text: secret, sensitive: true))
        }
        if value.payloads.first?.data == Data(secret.utf8) {
          secretRaw = value
          break
        }
      }
      guard let secretRaw else { throw TextClipboardError.timeout }
      check("native_secret_marker_reaches_core", secretRaw.isSensitive, into: &checks)
      await store.insert(secretRaw)
      await store.flush()
      let reopened = try await JSONSnapshotClipStore(root: root)
      let persisted = await reopened.all()
      let memory = await store.all()
      let blobFiles = try FileManager.default.contentsOfDirectory(
        at: root.appendingPathComponent("blobs"), includingPropertiesForKeys: nil)
      let secretBytes = Data(secret.utf8)
      let secretOnDisk = try blobFiles.contains {
        try Data(contentsOf: $0).range(of: secretBytes) != nil
      }
      check(
        "native_secret_is_memory_only",
        memory.contains(where: \.sensitive) && persisted.count == 1 && !secretOnDisk,
        into: &checks)
      stage = "size_rejection"
      let skip = try await nextValue(monitor.skips) {
        _ = try peer.request(
          PeerCommand(operation: "write", text: String(repeating: "x", count: 8192)))
      }
      check("oversized_native_text_is_rejected", skip.reason == "tooLarge", into: &checks)
    } catch {
      check(
        "platform_clipboard_operation", false,
        detail: "Native operation failed at \(stage); clipboard contents are not logged.",
        into: &checks)
    }
    return Report(
      scenario: "platform-clipboard", passed: checks.allSatisfy(\.passed), checks: checks)
  }
#else
  func runPlatformClipboard() async -> Report {
    Report(
      scenario: "platform-clipboard", passed: false,
      checks: [
        CheckResult(
          name: "supported_platform", passed: false,
          detail: "This experiment requires Windows or Linux X11.")
      ])
  }
#endif
