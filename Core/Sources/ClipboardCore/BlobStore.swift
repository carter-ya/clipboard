import Foundation

/// Manages reference-counted blob storage under `<root>/blobs/`.
/// Blobs are deduplicated by their own sha256; the same byte sequence
/// stored under multiple ClipItems only occupies one file on disk.
public actor BlobStore {
  private let root: URL
  private let fileManager: FileManager
  private var refCounts: [String: Int] = [:]

  public init(root: URL, fileManager: FileManager = .default) throws {
    self.root = root
    self.fileManager = fileManager
    try fileManager.createDirectory(at: root, withIntermediateDirectories: true)
  }

  /// Rebuild the refcount table from authoritative ClipItems.
  /// Called once after loading history on startup.
  public func rebuildRefCounts(from items: [ClipItem]) {
    refCounts.removeAll(keepingCapacity: true)
    for item in items {
      for payload in item.payloads {
        guard let sha = payload.blobSHA256 else { continue }
        refCounts[sha, default: 0] += 1
      }
    }
  }

  /// Write `data` under `<sha>.<ext>` if not already present; return the
  /// relative path. Increments refcount. If the blob already exists with
  /// a different ext, the first-seen ext wins.
  public func store(data: Data, sha256: String, ext: String) throws -> String {
    let existing = findExistingBlobPath(for: sha256)
    let relativePath = existing ?? "\(sha256).\(ext)"
    let fullURL = root.appendingPathComponent(relativePath)
    if existing == nil {
      try data.write(to: fullURL, options: .atomic)
    }
    refCounts[sha256, default: 0] += 1
    return relativePath
  }

  /// Increment refcount for an existing blob (used on dedup hits).
  public func retain(sha256: String) {
    refCounts[sha256, default: 0] += 1
  }

  /// Decrement refcount; if zero, delete the file. Returns whether the
  /// file was deleted.
  public func release(sha256: String) -> Bool {
    guard let count = refCounts[sha256], count > 0 else { return false }
    if count == 1 {
      refCounts.removeValue(forKey: sha256)
      if let path = findExistingBlobPath(for: sha256) {
        try? fileManager.removeItem(at: root.appendingPathComponent(path))
        return true
      }
      return false
    }
    refCounts[sha256] = count - 1
    return false
  }

  /// Delete any file under `blobs/` whose sha256 component is not in the
  /// current refcount table. Returns the number of files deleted.
  public func reconcile() throws -> Int {
    let contents = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil,
      options: .skipsHiddenFiles
    )
    var deleted = 0
    for url in contents {
      let name = url.lastPathComponent
      let sha = shaFrom(filename: name)
      if refCounts[sha] == nil {
        try? fileManager.removeItem(at: url)
        deleted += 1
      }
    }
    return deleted
  }

  /// Load a blob's raw bytes by its relative path.
  public func load(relativePath: String) throws -> Data {
    try Data(contentsOf: root.appendingPathComponent(relativePath))
  }

  /// Test-only: snapshot current refcount table.
  public var currentRefCounts: [String: Int] { refCounts }

  /// Test-only: list files currently under `blobs/`.
  public func listFiles() throws -> [String] {
    let contents = try fileManager.contentsOfDirectory(
      at: root,
      includingPropertiesForKeys: nil,
      options: .skipsHiddenFiles
    )
    return contents.map(\.lastPathComponent).sorted()
  }

  // MARK: - Helpers

  private func findExistingBlobPath(for sha: String) -> String? {
    guard
      let contents = try? fileManager.contentsOfDirectory(
        at: root,
        includingPropertiesForKeys: nil,
        options: .skipsHiddenFiles
      )
    else { return nil }
    return contents.first { $0.lastPathComponent.hasPrefix("\(sha).") }?.lastPathComponent
  }

  private func shaFrom(filename: String) -> String {
    if let dot = filename.firstIndex(of: ".") {
      return String(filename[..<dot])
    }
    return filename
  }
}
