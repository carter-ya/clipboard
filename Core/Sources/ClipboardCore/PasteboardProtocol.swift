import AppKit
import Foundation

public protocol PasteboardProtocol {
  var changeCount: Int { get }
  var availableTypes: [NSPasteboard.PasteboardType]? { get }
  func data(for type: NSPasteboard.PasteboardType) -> Data?
}

extension NSPasteboard: PasteboardProtocol {
  public var availableTypes: [NSPasteboard.PasteboardType]? { types }

  public func data(for type: NSPasteboard.PasteboardType) -> Data? {
    data(forType: type)
  }
}
