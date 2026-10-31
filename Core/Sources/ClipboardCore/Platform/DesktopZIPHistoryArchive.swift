import Foundation
import ZIPFoundation

/// Interoperates with the Mac history.json + blobs layout. No entry is ever
/// extracted to its archived path; only validated bytes reach the caller.
enum DesktopZIPHistoryArchive {
  private struct Envelope: Codable {
    var version = 1
    var items: [ClipItem]
  }
  private static let itemLimit = 16 * 1024 * 1024
  private static let entryLimit = 60_000
  private static let itemCountLimit = 10_000
  private typealias Failure = DesktopHistoryArchive.ArchiveError

  static func write(items: [ClipItem], blobRoot: URL?, to destination: URL) throws {
    guard items.count <= itemCountLimit else { throw Failure.tooLarge }
    let encoder = JSONEncoder()
    encoder.dateEncodingStrategy = .iso8601
    encoder.outputFormatting = [.sortedKeys]
    var history = Data("{\"version\":1,\"items\":[".utf8)
    var exportedCount = 0
    var blobs: [String: Data] = [:]
    var total = 0
    for item in items where !excluded(item) {
      try validateMetadata(item)
      var copy = item
      var size = 0
      var raw: [RawPayload] = []
      copy.payloads = try item.payloads.map { payload in
        let data = try exportedBytes(payload, blobRoot: blobRoot)
        guard data.count <= itemLimit - size else { throw Failure.tooLarge }
        size += data.count
        raw.append(.init(pasteboardType: payload.pasteboardType, data: data))
        if data.count <= 16 * 1024 {
          return Payload(pasteboardType: payload.pasteboardType, inlineData: data)
        }
        let name = Hashing.sha256(of: data) + "." + payload.pasteboardType.blobExtension
        if blobs[name] == nil {
          guard data.count <= DesktopHistoryArchive.maxBytes - total else { throw Failure.tooLarge }
          total += data.count
          blobs[name] = data
        }
        return Payload(pasteboardType: payload.pasteboardType, blobPath: name)
      }
      copy.sizeBytes = size
      copy.sha256 = Hashing.sha256(of: raw)
      copy.kind = ClipKind.infer(from: raw)
      copy.preview = PreviewBuilder.build(for: raw)
      copy.sensitivityReason = nil
      let encoded = try encoder.encode(copy)
      guard encoded.count + 3 <= DesktopHistoryArchive.maxBytes - total - history.count else {
        throw Failure.tooLarge
      }
      if exportedCount > 0 { history.append(44) }
      history.append(encoded)
      exportedCount += 1
    }
    history.append(contentsOf: [93, 125])
    guard blobs.count + 1 <= entryLimit else { throw Failure.tooLarge }
    try temporary { file in
      try createZIP(at: file, history: history, blobs: blobs)
      let bytes = try DesktopHistoryArchive.boundedData(
        from: file, limit: DesktopHistoryArchive.maxBytes)
      try bytes.write(to: destination, options: .atomic)
    }
  }

  private static func createZIP(at file: URL, history: Data, blobs: [String: Data]) throws {
    let archive = try Archive(url: file, accessMode: .create)
    func add(_ path: String, _ bytes: Data) throws {
      try archive.addEntry(
        with: path, type: .file, uncompressedSize: Int64(bytes.count), compressionMethod: .deflate
      ) { position, count in
        let start = Int(position)
        guard start >= 0, start <= bytes.count, count <= bytes.count - start else {
          throw Failure.invalidArchive
        }
        return bytes.subdata(in: start..<(start + count))
      }
    }
    try add("history.json", history)
    for name in blobs.keys.sorted() { try add("blobs/" + name, blobs[name]!) }
  }

  static func read(_ data: Data) throws -> DesktopHistoryArchive.ReadResult {
    let expectedCount = try entryCount(in: data)
    return try temporary { file in
      try data.write(to: file, options: .atomic)
      return try decodeZIP(at: file, expectedCount: expectedCount)
    }
  }

  private static func decodeZIP(at file: URL, expectedCount: Int) throws
    -> DesktopHistoryArchive.ReadResult
  {
    let archive = try Archive(url: file, accessMode: .read)
    var entries: [String: Entry] = [:]
    var names = Set<String>()
    var total: UInt64 = 0
    var historyPaths: [String] = []
    for entry in archive {
      guard entries.count < entryLimit, entry.type != .symlink,
        validPath(entry.path, directory: entry.type == .directory),
        names.insert(entry.path.precomposedStringWithCanonicalMapping.lowercased()).inserted
      else { throw Failure.invalidArchive }
      guard entry.uncompressedSize <= UInt64(DesktopHistoryArchive.maxBytes) - total else {
        throw Failure.tooLarge
      }
      total += entry.uncompressedSize
      entries[entry.path] = entry
      let components = entry.path.split(separator: "/")
      if entry.type == .file, components.last == "history.json", components.count <= 2 {
        historyPaths.append(entry.path)
      }
    }
    guard entries.count == expectedCount, historyPaths.count == 1,
      let historyPath = historyPaths.first, let historyEntry = entries[historyPath]
    else { throw Failure.invalidArchive }
    let prefix = String(historyPath.dropLast("history.json".count))
    let decoder = JSONDecoder()
    decoder.dateDecodingStrategy = .iso8601
    let envelope = try decoder.decode(
      Envelope.self,
      from: bytes(historyEntry, archive: archive, limit: DesktopHistoryArchive.maxBytes))
    guard envelope.version == 1, envelope.items.count <= itemCountLimit else {
      throw Failure.invalidArchive
    }
    var validated: [ClipItem] = []
    var skipped = 0
    var missing = 0
    var resolvedBytes = 0
    var hashes = Set<String>()
    var blobCache: [String: Data] = [:]
    for item in envelope.items {
      if excluded(item) {
        skipped += 1
        continue
      }
      try validateMetadata(item)
      var payloads: [RawPayload] = []
      var size = 0
      var hasMissingBlob = false
      for payload in item.payloads {
        let data: Data
        if let inline = payload.inlineData {
          guard payload.blobPath == nil else { throw Failure.invalidArchive }
          data = inline
        } else {
          guard let name = payload.blobPath, validBlobName(name) else { throw Failure.externalBlob }
          guard let entry = entries[prefix + "blobs/" + name] else {
            hasMissingBlob = true
            continue
          }
          guard entry.type == .file else { throw Failure.invalidArchive }
          if let cached = blobCache[name] {
            data = cached
          } else {
            data = try bytes(
              entry, archive: archive,
              limit: min(itemLimit, DesktopHistoryArchive.maxBytes - resolvedBytes))
            guard Hashing.sha256(of: data) == String(name.prefix(64)) else {
              throw Failure.invalidArchive
            }
            blobCache[name] = data
          }
        }
        guard data.count <= itemLimit - size else { throw Failure.tooLarge }
        guard data.count <= DesktopHistoryArchive.maxBytes - resolvedBytes else {
          throw Failure.tooLarge
        }
        resolvedBytes += data.count
        size += data.count
        payloads.append(.init(pasteboardType: payload.pasteboardType, data: data))
      }
      if hasMissingBlob {
        missing += 1
        continue
      }
      guard !payloads.isEmpty else {
        skipped += 1
        continue
      }
      var copy = item
      copy.id = UUID()
      copy.payloads = payloads.map { .init(pasteboardType: $0.pasteboardType, inlineData: $0.data) }
      copy.sha256 = Hashing.sha256(of: payloads)
      guard hashes.insert(copy.sha256).inserted else {
        skipped += 1
        continue
      }
      copy.kind = ClipKind.infer(from: payloads)
      copy.preview = PreviewBuilder.build(for: payloads)
      copy.sizeBytes = size
      copy.sensitivityReason = nil
      validated.append(copy)
    }
    return .init(items: validated, skipped: skipped, blobsMissing: missing)
  }

  private static func bytes(_ entry: Entry, archive: Archive, limit: Int) throws -> Data {
    guard entry.uncompressedSize <= UInt64(limit) else { throw Failure.tooLarge }
    var data = Data()
    let checksum = try archive.extract(entry, bufferSize: 64 * 1024) { chunk in
      guard chunk.count <= limit - data.count else { throw Failure.tooLarge }
      data.append(chunk)
    }
    guard UInt64(data.count) == entry.uncompressedSize, checksum == entry.checksum else {
      throw Failure.invalidArchive
    }
    return data
  }

  static func validateMetadata(_ item: ClipItem) throws {
    guard item.payloads.count <= 64 else { throw Failure.tooLarge }
    let fields = [
      item.preview, item.sha256, item.sourceBundleID ?? "", item.summary ?? "",
      item.sensitivityReason ?? "",
    ]
    var count = 0
    for field in fields + item.payloads.map(\.pasteboardType) {
      guard field.utf8.count <= itemLimit - count else { throw Failure.tooLarge }
      count += field.utf8.count
    }
  }

  static func exportedBytes(_ payload: Payload, blobRoot: URL?) throws -> Data {
    if let inline = payload.inlineData {
      guard payload.blobPath == nil, inline.count <= itemLimit else { throw Failure.tooLarge }
      return inline
    }
    guard let name = payload.blobPath, validBlobName(name), let blobRoot else {
      throw Failure.externalBlob
    }
    let file = blobRoot.appendingPathComponent(name)
    guard try file.resourceValues(forKeys: [.isSymbolicLinkKey]).isSymbolicLink != true else {
      throw Failure.externalBlob
    }
    let data = try DesktopHistoryArchive.boundedData(from: file, limit: itemLimit)
    guard Hashing.sha256(of: data) == String(name.prefix(64)) else { throw Failure.invalidArchive }
    return data
  }

  private static func excluded(_ item: ClipItem) -> Bool {
    item.sensitive
      || item.payloads.contains { $0.pasteboardType == SensitivityFilter.concealedType }
  }

  private static func validBlobName(_ name: String) -> Bool {
    let pieces = name.split(separator: ".", omittingEmptySubsequences: false)
    return pieces.count == 2 && pieces[0].count == 64
      && pieces[0].allSatisfy { $0.isASCII && ($0.isNumber || ("a"..."f").contains(String($0))) }
      && !pieces[1].isEmpty && pieces[1].count <= 16
      && pieces[1].allSatisfy { $0.isASCII && ($0.isLetter || $0.isNumber) }
  }

  private static func validPath(_ path: String, directory: Bool) -> Bool {
    guard !path.isEmpty, path.utf8.count <= 4096,
      !path.contains("\\"), !path.contains(":"), !path.contains("\0")
    else { return false }
    var parts = path.split(separator: "/", omittingEmptySubsequences: false)
    if directory && parts.last == "" { parts.removeLast() }
    return !parts.isEmpty && parts.allSatisfy { !$0.isEmpty && $0 != "." && $0 != ".." }
  }

  /// Check the bounded ZIP32 directory before the library trusts its counts or
  /// offsets. ZIP64/multi-disk archives exceed this format's supported bounds.
  private static func entryCount(in data: Data) throws -> Int {
    guard data.count >= 22 else { throw Failure.invalidArchive }
    func value(_ offset: Int, _ count: Int) -> UInt64 {
      (0..<count).reduce(0) { $0 | UInt64(data[offset + $1]) << ($1 * 8) }
    }
    let minimum = max(0, data.count - 65557)
    for offset in stride(from: data.count - 22, through: minimum, by: -1) {
      guard value(offset, 4) == 0x0605_4b50,
        offset + 22 + Int(value(offset + 20, 2)) == data.count
      else { continue }
      let count = value(offset + 10, 2)
      let size = value(offset + 12, 4)
      let start = value(offset + 16, 4)
      guard value(offset + 4, 2) == 0, value(offset + 6, 2) == 0,
        count == value(offset + 8, 2), count <= UInt64(entryLimit),
        offset < 20 || value(offset - 20, 4) != 0x0706_4b50,
        size < UInt64(UInt32.max), start < UInt64(UInt32.max),
        start + size <= UInt64(offset), count * 46 <= size
      else { throw Failure.invalidArchive }
      return Int(count)
    }
    throw Failure.invalidArchive
  }

  private static func temporary<T>(_ action: (URL) throws -> T) throws -> T {
    let directory = FileManager.default.temporaryDirectory.appendingPathComponent(
      "clipboard-zip-" + UUID().uuidString)
    #if os(Windows)
      try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: false)
    #else
      try FileManager.default.createDirectory(
        at: directory, withIntermediateDirectories: false, attributes: [.posixPermissions: 0o700])
    #endif
    defer { try? FileManager.default.removeItem(at: directory) }
    return try action(directory.appendingPathComponent("archive.zip"))
  }
}
