import Foundation

public protocol PasteboardWriter {
  func write(_ item: ClipItem) throws
}
