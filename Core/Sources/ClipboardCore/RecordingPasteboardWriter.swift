import Foundation

public final class RecordingPasteboardWriter: PasteboardWriting, @unchecked Sendable {
  public private(set) var writes: [ClipItem] = []
  public var onWrite: ((ClipItem) -> Void)?

  public init() {}

  public func write(_ item: ClipItem) throws {
    writes.append(item)
    onWrite?(item)
  }
}
