import ClipboardCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if os(Linux) || os(Windows)
  import DesktopServices
  #if os(Linux)
    import Glibc
  #endif

  func runPlatformServices() async -> Report {
    var checks: [CheckResult] = []
    guard ProcessInfo.processInfo.environment["CLIPBOARD_PRIVATE_SERVICES_TEST"] == "1" else {
      return .init(
        scenario: "platform-services", passed: false,
        checks: [.init(name: "private_fixture_required", passed: false, detail: nil)])
    }
    let watchdog = DispatchSource.makeTimerSource(queue: .global())
    watchdog.schedule(deadline: .now() + 120)
    watchdog.setEventHandler { exit(2) }
    watchdog.resume()
    defer { watchdog.cancel() }
    let credentials = NativeDesktopCredentials()
    let identity = UUID().uuidString
    let account = DesktopProfileIdentity.namespace(for: "credential-fixture-" + identity)
    do {
      let missing = try await credentials.read(account: account)
      check("native_credential_starts_absent", missing == nil, into: &checks)
      try await credentials.save("synthetic credential 中文", account: account)
      let first = try await credentials.read(account: account)
      check(
        "native_credential_unicode_roundtrip", first == "synthetic credential 中文", into: &checks)
      try await credentials.save("updated synthetic credential", account: account)
      let next = try await credentials.read(account: account)
      check(
        "native_credential_updates_existing_item", next == "updated synthetic credential",
        into: &checks)
      try await credentials.delete(account: account)
      let deleted = try await credentials.read(account: account)
      check("native_credential_deletion", deleted == nil, into: &checks)
    } catch {
      check(
        "native_secure_credential_service", false, detail: "secure_service_unavailable",
        into: &checks)
    }
    try? await credentials.delete(account: account)
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clipboard-services-" + identity)
    defer { try? FileManager.default.removeItem(at: root) }
    do {
      let startup = try NativeDesktopStartup(
        executable: URL(fileURLWithPath: CommandLine.arguments[0]).standardizedFileURL,
        name: "com.clipboard.desktop.fixture." + identity, configRoot: root)
      let absent = try await startup.isEnabled()
      check("startup_fixture_starts_disabled", !absent, into: &checks)
      do {
        try await startup.setEnabled(true)
        let enabled = try await startup.isEnabled()
        check("startup_registers_user_owned_entry", enabled, into: &checks)
        #if os(Linux)
          let entry = root.appendingPathComponent("autostart")
            .appendingPathComponent("com.clipboard.desktop.fixture." + identity + ".desktop")
          let original = try Data(contentsOf: entry)
          var decorated = Data("# desktop settings comment\n".utf8)
          decorated.append(original)
          decorated.append(Data("NoDisplay=true\n".utf8))
          try decorated.write(to: entry, options: .atomic)
          let unchanged = try await startup.isEnabled()
          check("startup_ignores_presentation_only_edits", unchanged, into: &checks)
          for (key, value) in [
            ("Hidden", "true"), ("OnlyShowIn", "ClipboardFixture-" + identity + ";"),
            ("TryExec", root.appendingPathComponent("not-installed").path),
          ] {
            var restricted = original
            restricted.append(Data("\(key)=\(value)\n".utf8))
            try restricted.write(to: entry, options: .atomic)
            let disabled = try await startup.isEnabled()
            let preserved = try Data(contentsOf: entry) == restricted
            check("startup_honors_" + key, !disabled && preserved, into: &checks)
            try await startup.setEnabled(true)
          }
          let tryProgram = root.appendingPathComponent("synthetic program")
          try Data("#!/bin/sh\nexit 0\n".utf8).write(to: tryProgram)
          try FileManager.default.setAttributes(
            [.posixPermissions: 0o700], ofItemAtPath: tryProgram.path)
          var executableEntry = original
          executableEntry.append(
            Data(
              ("TryExec=" + tryProgram.path.replacingOccurrences(of: " ", with: "\\s") + "\n").utf8)
          )
          try executableEntry.write(to: entry, options: .atomic)
          let installedProgram = try await startup.isEnabled()
          check("startup_accepts_escaped_installed_tryexec", installedProgram, into: &checks)
          let gnomeDisabled = String(decoding: original, as: UTF8.self)
            .replacingOccurrences(
              of: "X-GNOME-Autostart-enabled=true", with: "X-GNOME-Autostart-enabled=false")
          try Data(gnomeDisabled.utf8).write(to: entry, options: .atomic)
          let gnomeEnabled = try await startup.isEnabled()
          check("startup_honors_session_disabled_flag", !gnomeEnabled, into: &checks)
          try await startup.setEnabled(true)
          for (suffix, body) in [
            ("duplicate_command", original + Data("Exec=/not-this-installation\n".utf8)),
            ("oversized_entry", Data(repeating: 32, count: 65537)),
          ] {
            try body.write(to: entry, options: .atomic)
            var refused = false
            do { try await startup.setEnabled(false) } catch {
              refused = error as? DesktopServiceError == .startupConflict
            }
            let preserved = try Data(contentsOf: entry) == body
            check("startup_preserves_" + suffix, refused && preserved, into: &checks)
            try original.write(to: entry, options: .atomic)
          }
          let target = root.appendingPathComponent("unrelated-entry")
          try original.write(to: target)
          try FileManager.default.removeItem(at: entry)
          try FileManager.default.createSymbolicLink(at: entry, withDestinationURL: target)
          var refusedLink = false
          do { try await startup.setEnabled(true) } catch {
            refusedLink = error as? DesktopServiceError == .startupConflict
          }
          let targetPreserved = try Data(contentsOf: target) == original
          check(
            "startup_preserves_symlink_and_target", refusedLink && targetPreserved, into: &checks)
          try FileManager.default.removeItem(at: entry)
          try original.write(to: entry, options: .atomic)
        #endif
      } catch {
        try? await startup.setEnabled(false)
        throw error
      }
      try await startup.setEnabled(false)
      let removed = try await startup.isEnabled()
      check("startup_removes_only_fixture_entry", !removed, into: &checks)
      let otherStartup = try NativeDesktopStartup(
        executable: root.appendingPathComponent("another-installation"),
        name: "com.clipboard.desktop.fixture." + identity, configRoot: root)
      do {
        try await otherStartup.setEnabled(true)
        var readRefused = false
        do { _ = try await startup.isEnabled() } catch {
          readRefused = error as? DesktopServiceError == .startupConflict
        }
        check("startup_reports_other_installation_conflict", readRefused, into: &checks)
        for desired in [true, false] {
          var refused = false
          do { try await startup.setEnabled(desired) } catch {
            refused = error as? DesktopServiceError == .startupConflict
          }
          check(
            desired ? "startup_refuses_foreign_replacement" : "startup_refuses_foreign_removal",
            refused, into: &checks)
        }
        let foreignPreserved = try await otherStartup.isEnabled()
        check("startup_preserves_other_installation_entry", foreignPreserved, into: &checks)
        try await otherStartup.setEnabled(false)
      } catch {
        try? await otherStartup.setEnabled(false)
        throw error
      }
    } catch {
      check("native_startup_service", false, detail: "startup_fixture_unavailable", into: &checks)
    }
    var fileStage = "create_private_file_directory"
    do {
      let directory = root.appendingPathComponent("file text 中文")
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
      let file = directory.appendingPathComponent("fixture 中文😀.TXT")
      let body =
        "Private native file fixture 中文😀\n" + String(repeating: "Local context. ", count: 20)
      try Data(body.utf8).write(to: file)
      let reader = NativeDesktopFileTextReader()
      fileStage = "read_unicode_regular_file"
      let first = try await reader.text(from: file, maxBytes: 4096)
      check("native_file_text_unicode_roundtrip", first == body, into: &checks)
      guard let serialized = URL(string: file.absoluteString) else {
        throw DesktopServiceError.invalidValue
      }
      let reopened = try await reader.text(from: serialized, maxBytes: 4096)
      check("native_file_url_roundtrip_preserves_local_path", reopened == body, into: &checks)
      fileStage = "read_private_pdf_text"
      let pdf = directory.appendingPathComponent("fixture 中文😀.PDF")
      let pdfText =
        "Synthetic native PDF text stays private. "
        + String(repeating: "Local context. ", count: 10)
      try syntheticPDFText(pdfText).write(to: pdf)
      let extracted = try await reader.text(from: pdf, maxBytes: 4096)
      check(
        "native_pdf_text_body_is_extracted_without_file_paths",
        extracted.trimmingCharacters(in: .whitespacesAndNewlines)
          == pdfText.trimmingCharacters(in: .whitespacesAndNewlines), into: &checks)
      for (name, bytes, failure) in [
        ("malformed", Data("%PDF-private-invalid".utf8), DesktopServiceError.invalidValue),
        ("empty", syntheticPDFText(""), .invalidValue),
        ("pages", syntheticPDFText("Synthetic page budget", pages: 257), .tooLarge),
      ] {
        fileStage = "reject_private_pdf_" + name
        try bytes.write(to: pdf)
        var rejectedPDF = false
        do { _ = try await reader.text(from: pdf, maxBytes: 4096) } catch {
          rejectedPDF = error as? DesktopServiceError == failure
        }
        check("native_pdf_\(name)_is_rejected", rejectedPDF, into: &checks)
      }
      fileStage = "read_at_exact_byte_limit"
      try Data(repeating: 65, count: 128).write(to: file)
      let exact = try await reader.text(from: file, maxBytes: 128)
      check("native_file_exact_byte_limit_is_accepted", exact.utf8.count == 128, into: &checks)
      try Data(repeating: 65, count: 129).write(to: file)
      var rejected = false
      do { _ = try await reader.text(from: file, maxBytes: 128) } catch DesktopServiceError.tooLarge
      { rejected = true }
      check("native_file_over_byte_limit_is_rejected", rejected, into: &checks)
      for (index, data) in [Data([0xff]), Data([65, 0, 66])].enumerated() {
        fileStage = "reject_binary_or_invalid_text"
        try data.write(to: file)
        rejected = false
        do { _ = try await reader.text(from: file, maxBytes: 128) } catch DesktopServiceError
          .invalidValue
        { rejected = true }
        check("native_file_invalid_text_\(index)_is_rejected", rejected, into: &checks)
      }
      fileStage = "reject_directory"
      let folder = directory.appendingPathComponent("directory.txt", isDirectory: true)
      try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: false)
      rejected = false
      do { _ = try await reader.text(from: folder, maxBytes: 128) } catch DesktopServiceError
        .invalidValue
      { rejected = true }
      check("native_file_directory_is_rejected", rejected, into: &checks)
      fileStage = "reject_final_symlink"
      try Data(body.utf8).write(to: file)
      let link = directory.appendingPathComponent("link.txt")
      try FileManager.default.createSymbolicLink(at: link, withDestinationURL: file)
      rejected = false
      do { _ = try await reader.text(from: link, maxBytes: 4096) } catch DesktopServiceError
        .invalidValue
      { rejected = true }
      check("native_file_symlink_is_rejected", rejected, into: &checks)
      #if os(Linux)
        fileStage = "reject_nonblocking_fifo"
        let fifo = directory.appendingPathComponent("pipe.txt")
        guard mkfifo(fifo.path, 0o600) == 0 else { throw DesktopServiceError.unavailable }
        rejected = false
        do { _ = try await reader.text(from: fifo, maxBytes: 128) } catch DesktopServiceError
          .invalidValue
        { rejected = true }
        check("native_file_fifo_is_rejected_without_waiting_for_writer", rejected, into: &checks)
      #endif
    } catch {
      check("native_file_text_reader", false, detail: fileStage, into: &checks)
    }
    do {
      let args = CommandLine.arguments
      guard let index = args.firstIndex(of: "--ocr-fixture"), index + 1 < args.count else {
        throw DesktopServiceError.invalidValue
      }
      let image = try Data(contentsOf: URL(fileURLWithPath: args[index + 1]))
      let ocr = NativeDesktopOCR()
      let text = try await ocr.recognize(image, language: "en")
      check(
        "native_ocr_reads_synthetic_fixture",
        text.uppercased().contains("CLIPBOARD") && text.contains("123"), into: &checks)
      var rejected = false
      do { _ = try await ocr.recognize(Data([0, 1, 2]), language: "en") } catch { rejected = true }
      check("native_ocr_rejects_invalid_image", rejected, into: &checks)
    } catch {
      check("native_ocr_service", false, detail: "ocr_fixture_unavailable", into: &checks)
    }
    do {
      let args = CommandLine.arguments
      guard let index = args.firstIndex(of: "--http-fixture"), index + 1 < args.count,
        let base = URL(string: args[index + 1]),
        ["127.0.0.1", "localhost"].contains(base.host ?? "")
      else { throw DesktopServiceError.invalidValue }
      let transport = BoundedDesktopAITransport()
      func request(_ route: String) -> URLRequest {
        var request = URLRequest(url: base.appendingPathComponent(route))
        request.httpMethod = "POST"
        request.httpBody = Data("synthetic fixture".utf8)
        request.timeoutInterval = 5
        return request
      }
      let response = try await transport.send(request("ok"), maxResponseBytes: 1024)
      check(
        "native_transport_receives_bounded_response",
        response.status == 200 && response.data == Data("fixture response".utf8), into: &checks)
      var rejected = false
      do {
        _ = try await transport.send(request("oversize"), maxResponseBytes: 1024)
      } catch DesktopServiceError.tooLarge { rejected = true }
      check("native_transport_rejects_oversized_response", rejected, into: &checks)
      let redirect = try await transport.send(request("redirect"), maxResponseBytes: 1024)
      check("native_transport_does_not_follow_redirects", redirect.status == 302, into: &checks)
    } catch {
      check("native_http_transport", false, detail: "http_fixture_unavailable", into: &checks)
    }
    return .init(
      scenario: "platform-services", passed: !checks.isEmpty && checks.allSatisfy(\.passed),
      checks: checks)
  }
#else
  func runPlatformServices() async -> Report {
    .init(
      scenario: "platform-services", passed: false,
      checks: [.init(name: "unsupported_platform", passed: false, detail: nil)])
  }
#endif
