import Foundation

/// Resolves a Payload's raw bytes from either its inline copy or its
/// blob file on disk.
public struct PayloadResolver: Sendable {
  private let blobRoot: URL?

  public init(blobRoot: URL?) {
    self.blobRoot = blobRoot
  }

  public func data(for payload: Payload) throws -> Data {
    if let inline = payload.inlineData {
      return inline
    }
    if let path = payload.blobPath, let root = blobRoot {
      do {
        return try Data(contentsOf: root.appendingPathComponent(path))
      } catch {
        throw PasteboardWriterError.blobLoadFailed(path: path)
      }
    }
    throw PasteboardWriterError.missingData(pasteboardType: payload.pasteboardType)
  }
}
