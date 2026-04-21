import Foundation

public struct Payload: Sendable, Codable, Equatable {
  public var pasteboardType: String
  public var inlineData: Data?
  public var blobPath: String?

  public init(
    pasteboardType: String,
    inlineData: Data? = nil,
    blobPath: String? = nil
  ) {
    self.pasteboardType = pasteboardType
    self.inlineData = inlineData
    self.blobPath = blobPath
  }

  /// sha256 of the blob referenced by blobPath, if any.
  /// Expects `blobPath` to be of the form `<hex>.<ext>`.
  public var blobSHA256: String? {
    guard let blobPath else { return nil }
    let name = (blobPath as NSString).lastPathComponent
    if let dot = name.firstIndex(of: ".") {
      return String(name[..<dot])
    }
    return name
  }
}
