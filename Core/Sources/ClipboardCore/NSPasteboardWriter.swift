import AppKit
import Foundation

public protocol PasteboardWriting {
  /// Write all payloads of the selected item to the system pasteboard.
  /// Does NOT simulate Cmd+V — user pastes manually.
  func write(_ item: ClipItem) throws
}

public enum PasteboardWriterError: Error, Equatable {
  case missingData(pasteboardType: String)
  case blobLoadFailed(path: String)
}

public final class NSPasteboardWriter: PasteboardWriting, @unchecked Sendable {
  private let pasteboard: NSPasteboard
  private let blobRoot: URL?

  public init(pasteboard: NSPasteboard = .general, blobRoot: URL? = nil) {
    self.pasteboard = pasteboard
    self.blobRoot = blobRoot
  }

  public func write(_ item: ClipItem) throws {
    let types = item.payloads.map { NSPasteboard.PasteboardType($0.pasteboardType) }
    pasteboard.clearContents()
    pasteboard.declareTypes(types, owner: nil)

    var totalBytes = 0
    var writtenTypes: [String] = []
    for payload in item.payloads {
      let data = try resolveData(for: payload)
      pasteboard.setData(data, forType: NSPasteboard.PasteboardType(payload.pasteboardType))
      totalBytes += data.count
      writtenTypes.append(payload.pasteboardType)
    }
    Log.paste.info(
      """
      paste.write{itemId:\(item.id.uuidString, privacy: .public), \
      types:\(writtenTypes, privacy: .public), \
      sizeBytes:\(totalBytes, privacy: .public), \
      sensitive:\(item.sensitive, privacy: .public)}
      """
    )
  }

  private func resolveData(for payload: Payload) throws -> Data {
    if let inline = payload.inlineData {
      return inline
    }
    if let blobPath = payload.blobPath, let root = blobRoot {
      let url = root.appendingPathComponent(blobPath)
      do {
        return try Data(contentsOf: url)
      } catch {
        throw PasteboardWriterError.blobLoadFailed(path: blobPath)
      }
    }
    throw PasteboardWriterError.missingData(pasteboardType: payload.pasteboardType)
  }
}
