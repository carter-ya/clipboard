import ClipboardCore
import Foundation

/// Fixed, content-free capability request. No model path or clipboard data is
/// needed to decide whether offering an optional model makes sense.
enum NativeDesktopModelCapability {
  static func executable(_ supplied: URL?, name: String) -> URL {
    if let supplied { return supplied }
    #if os(Windows)
      let filename = name + ".exe"
    #else
      let filename = name
    #endif
    return (Bundle.main.executableURL ?? URL(fileURLWithPath: CommandLine.arguments[0]))
      .deletingLastPathComponent().appendingPathComponent(filename)
  }
  static func isSupported(_ executable: URL, unavailable: Set<Int32> = []) async throws -> Bool {
    do {
      let bytes = try await NativeDesktopByteWorker(
        executable: executable, timeout: 3, inputLimit: 128, outputLimit: 128,
        unavailableExitCodes: unavailable
      ).run(Data("{\"task\":\"capability\"}".utf8))
      let value = try JSONSerialization.jsonObject(with: bytes) as? [String: Any]
      struct Response: Decodable { let available: Bool }
      guard value?.count == 1 else { return false }
      return try JSONDecoder().decode(Response.self, from: bytes).available
    } catch is CancellationError { throw CancellationError() } catch { return false }
  }
}
