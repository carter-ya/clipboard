import Foundation

public enum AppPaths {
  public static let defaultSupportDirectoryName = "Clipboard"

  /// Resolve a profile location without opening or creating its store.
  public static func defaultStoreLocation(
    fileManager: FileManager = .default,
    directoryName: String = defaultSupportDirectoryName
  ) throws -> URL {
    guard let base = fileManager.urls(for: .applicationSupportDirectory, in: .userDomainMask).first
    else {
      throw CocoaError(.fileNoSuchFile)
    }
    return base.appendingPathComponent(directoryName, isDirectory: true)
  }

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
