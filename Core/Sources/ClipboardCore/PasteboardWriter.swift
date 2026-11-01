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
