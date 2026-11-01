import ClipboardCore
import Foundation

#if os(Windows) || os(Linux)
  import DesktopClipboard

  private func richFixtures(_ name: String) -> [RawPayload] {
    if name == "local-summary" {
      let text = "This synthetic local summary stays on this device. "
        + String(repeating: "Additional private test context. ", count: 10)
      return [.init(pasteboardType: "public.utf8-plain-text", data: Data(text.utf8))]
    }
    if name == "preview-long" {
      let text =
        String(repeating: "Long preview fixture 中文😀\n", count: 4096)
        + "end-of-full-preview-fixture"
      return [.init(pasteboardType: "public.utf8-plain-text", data: Data(text.utf8))]
    }
    if name == "files" {
      return [
        .init(
          pasteboardType: "public.file-url",
          data: ClipboardFormats.fileURLData([
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fixture 中文.txt"),
            URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("fixture two.txt"),
          ]))
      ]
    }
    if name == "bmp" {
      // A valid 1x1, 24-bit BMP exercises Windows CF_DIB conversion.
      var bmp = Data(repeating: 0, count: 58)
      let header: [UInt8] = [
        0x42, 0x4d, 58, 0, 0, 0, 0, 0, 0, 0, 54, 0, 0, 0, 40, 0, 0, 0, 1, 0, 0, 0, 1, 0, 0, 0, 1, 0,
        24, 0,
      ]
      bmp.replaceSubrange(0..<header.count, with: header)
      return [.init(pasteboardType: "com.microsoft.bmp", data: bmp)]
    }
    if name == "tiff" {
      return [.init(pasteboardType: "public.tiff", data: Data([0x49, 0x49, 0x2a, 0, 8, 0, 0, 0]))]
    }
    if name == "jpeg" {
      return [.init(pasteboardType: "public.jpeg", data: Data([0xff, 0xd8, 0xff, 0xd9]))]
    }
    if name == "large" {
      // Opaque clipboard bytes test the bounded INCR transport, not image decoding.
      return [.init(pasteboardType: "public.png", data: Data(repeating: 0x42, count: 700 * 1024))]
    }
    let png =
      Data(
        base64Encoded:
          "iVBORw0KGgoAAAANSUhEUgAAABAAAAAQCAYAAAAf8/9hAAAAGUlEQVR4nGPQyLvznxLMMGrAqAGjBgwXAwBc3HEfVZuzFAAAAABJRU5ErkJggg=="
      ) ?? Data()
    return [
      .init(pasteboardType: "public.utf8-plain-text", data: Data("Fixture 中文\nsecond line".utf8)),
      .init(pasteboardType: "public.html", data: Data("<p>Fixture <b>中文</b></p>".utf8)),
      .init(pasteboardType: "public.rtf", data: Data("{\\rtf1\\ansi Fixture \\b bold\\b0}".utf8)),
      .init(pasteboardType: "public.png", data: png),
    ]
  }
  func runRichClipboardPeer() throws {
    let args = CommandLine.arguments
    if args.count > 2 && args[2] == "probe-restricted" {
      guard ProcessInfo.processInfo.environment["CLIPBOARD_PRIVATE_WAYLAND_TEST"] == "1" else {
        throw TextClipboardError.unavailable
      }
      do {
        _ = try SystemRichClipboard()
        throw TextClipboardError.invalidText
      } catch TextClipboardError.unsupportedSession {
        FileHandle.standardOutput.write(Data("restricted-ok\n".utf8))
        return
      }
    }
    let clipboard = try SystemRichClipboard()
    if args.count > 2 && args[2] == "read-text" {
      guard let snapshot = try clipboard.read(maxBytes: 1024),
        snapshot.payloads.contains(
          .init(pasteboardType: "public.utf8-plain-text", data: Data("Independent Wayland 中文".utf8))
        ),
        snapshot.sourceAppID == nil, !snapshot.sensitive
      else { throw TextClipboardError.invalidText }
      FileHandle.standardOutput.write(Data("readback-ok\n".utf8))
      return
    }
    if args.count > 2 && args[2] == "read" {
      guard let value = try clipboard.read(maxBytes: 16 * 1024 * 1024),
        value.payloads == richFixtures("large")
      else { throw TextClipboardError.invalidText }
      FileHandle.standardOutput.write(Data("readback-ok\n".utf8))
      return
    }
    let fixture = args.count > 2 ? args[2] : "rich"
    if fixture == "ocr", args.count > 3 {
      let data = try Data(contentsOf: URL(fileURLWithPath: args[3]))
      try clipboard.write(
        payloads: [.init(pasteboardType: "public.png", data: data)], sensitive: false)
    } else {
      try clipboard.write(payloads: richFixtures(fixture), sensitive: fixture == "secret")
    }
    FileHandle.standardOutput.write(Data("ready\n".utf8))
    _ = readLine()
  }
  private func richLine(_ pipe: Pipe) throws -> String {
    var data = Data()
    while data.last != 10 {
      let next = pipe.fileHandleForReading.readData(ofLength: 1)
      guard !next.isEmpty, data.count < 32 else { throw TextClipboardError.unavailable }
      data.append(next)
    }
    return String(decoding: data.dropLast(), as: UTF8.self)
  }
  func runPlatformRichClipboard() async -> Report {
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + 45)
    watchdog.setEventHandler { exit(2) }
    watchdog.resume()
    defer { watchdog.cancel() }
    var checks: [CheckResult] = []
    do {
      let clipboard = try SystemRichClipboard()
      for fixture in ["rich", "secret", "files", "bmp", "jpeg", "tiff", "large"] {
        let peer = Process()
        let input = Pipe()
        let output = Pipe()
        peer.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
        peer.arguments = ["rich-clipboard-peer", fixture]
        peer.standardInput = input
        peer.standardOutput = output
        try peer.run()
        defer {
          try? input.fileHandleForWriting.close()
          if peer.isRunning { peer.terminate() }
          peer.waitUntilExit()
        }
        guard try richLine(output) == "ready" else { throw TextClipboardError.unavailable }
        guard let snapshot = try clipboard.read(maxBytes: 16 * 1024 * 1024) else {
          throw TextClipboardError.unavailable
        }
        let expected = richFixtures(fixture)
        check(
          "independent_\(fixture)_formats_roundtrip", snapshot.payloads == expected, into: &checks)
        check(
          "independent_\(fixture)_sensitivity", snapshot.sensitive == (fixture == "secret"),
          into: &checks)
        #if os(Linux)
          check(
            "independent_\(fixture)_source_owner_identity",
            (ProcessInfo.processInfo.environment["WAYLAND_DISPLAY"] == nil
              ? snapshot.sourceAppID == "linux:ClipboardDesktop" : snapshot.sourceAppID == nil),
            into: &checks)
        #endif
        if fixture == "large" {
          var rejected = false
          do { _ = try clipboard.read(maxBytes: 1024) } catch TextClipboardError.tooLarge {
            rejected = true
          }
          check("oversized_native_transfer_rejected", rejected, into: &checks)
        }
        try? input.fileHandleForWriting.close()
        peer.waitUntilExit()
      }
      try clipboard.write(payloads: richFixtures("large"), sensitive: false)
      let reader = Process()
      let result = Pipe()
      reader.executableURL = URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL
      reader.arguments = ["rich-clipboard-peer", "read"]
      reader.standardOutput = result
      try reader.run()
      let reply = try richLine(result)
      reader.waitUntilExit()
      check(
        "independent_reader_receives_large_owned_payload",
        reply == "readback-ok" && reader.terminationStatus == 0, into: &checks)
    } catch {
      check(
        "native_rich_clipboard", false, detail: "native_rich_transfer_unavailable", into: &checks)
    }
    return .init(
      scenario: "platform-rich-clipboard", passed: !checks.isEmpty && checks.allSatisfy(\.passed),
      checks: checks)
  }
#else
  func runPlatformRichClipboard() async -> Report {
    .init(
      scenario: "platform-rich-clipboard", passed: false,
      checks: [.init(name: "unsupported_platform", passed: false, detail: nil)])
  }
#endif
