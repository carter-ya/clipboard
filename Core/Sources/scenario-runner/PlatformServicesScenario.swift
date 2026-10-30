import ClipboardCore
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif
#if os(Linux) || os(Windows)
  import DesktopServices

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
      } catch {
        try? await startup.setEnabled(false)
        throw error
      }
      try await startup.setEnabled(false)
      let removed = try await startup.isEnabled()
      check("startup_removes_only_fixture_entry", !removed, into: &checks)
    } catch {
      check("native_startup_service", false, detail: "startup_fixture_unavailable", into: &checks)
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
