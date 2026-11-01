import ClipboardCore
import DesktopServices
import Foundation

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

/// Private synthetic UI runs only. Production always queries the fixed official
/// endpoint and cannot take an endpoint from settings, arguments or environment.
enum DesktopUpdateFixture {
  @MainActor static func transport() -> any DesktopAITransport {
    guard CommandLine.arguments.contains("--smoke-root"),
      CommandLine.arguments.contains("--smoke-updates"),
      DesktopApplicationContext.profile != "production",
      let value = ProcessInfo.processInfo.environment["CLIPBOARD_PRIVATE_UPDATE_PORT"],
      let port = UInt16(value), port > 0
    else { return BoundedDesktopAITransport() }
    return Loopback(port: port)
  }
  private struct Loopback: DesktopAITransport {
    let port: UInt16
    func send(_ request: URLRequest, maxResponseBytes: Int) async throws -> DesktopHTTPResponse {
      guard
        request.url?.absoluteString
          == "https://api.github.com/repos/carter-ya/clipboard/releases?per_page=20",
        request.httpMethod == "GET", request.httpBody == nil,
        request.value(forHTTPHeaderField: "Authorization") == nil,
        request.value(forHTTPHeaderField: "Cookie") == nil,
        let url = URL(string: "http://127.0.0.1:\(port)/releases?per_page=20")
      else { throw DesktopServiceError.invalidValue }
      var local = request
      local.url = url
      return try await BoundedDesktopAITransport().send(local, maxResponseBytes: maxResponseBytes)
    }
  }
}
