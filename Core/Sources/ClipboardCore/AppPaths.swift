import Foundation

public enum AppPaths {
  public static let defaultSupportDirectoryName = "Clipboard"

  /// `~/Library/Application Support/Clipboard/` by default.
  public static func defaultStoreRoot(
    fileManager: FileManager = .default,
    directoryName: String = defaultSupportDirectoryName
  ) throws -> URL {
    let base = try fileManager.url(
      for: .applicationSupportDirectory,
      in: .userDomainMask,
      appropriateFor: nil,
      create: true
    )
    let root = base.appendingPathComponent(directoryName)
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
    return root
  }
}
