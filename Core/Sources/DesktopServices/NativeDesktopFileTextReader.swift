import CDesktopServices
import ClipboardCore
import Foundation

public struct NativeDesktopFileTextReader: DesktopFileTextReading {
  public init() {}
  public func text(from file: URL, maxBytes: Int) async throws -> String {
    try DesktopFileTextPolicy.validate(file)
    guard (1...(16 * 1024 * 1024)).contains(maxBytes) else {
      throw DesktopServiceError.invalidValue
    }
    try Task.checkCancellation()
    let data = try await Task.detached {
      var bytes: UnsafeMutablePointer<UInt8>?
      var length = 0
      let status = file.standardizedFileURL.withUnsafeFileSystemRepresentation {
        cds_file_read($0, maxBytes, &bytes, &length)
      }
      defer { if let bytes { cds_free(bytes) } }
      if status == -4 { throw DesktopServiceError.tooLarge }
      guard status == 1, let bytes, length <= maxBytes else {
        throw status == -2 ? DesktopServiceError.invalidValue : .fileUnavailable
      }
      return Data(bytes: bytes, count: length)
    }.value
    try Task.checkCancellation()
    guard let text = String(data: data, encoding: .utf8), !text.contains("\0"),
      !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    else { throw DesktopServiceError.invalidValue }
    return text
  }
}
