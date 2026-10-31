import Foundation

/// Mac-compatible ZIP and legacy self-contained JSON history archives.
/// Only non-sensitive history is included; all blob bytes are resolved in memory.
public enum DesktopHistoryArchive {
  public enum ArchiveError: Error { case tooLarge, invalidArchive, externalBlob }
  private struct Envelope: Codable {
    var version = 1
    var items: [ClipItem]
  }
  public struct ReadResult: Sendable {
    public let items: [ClipItem]
    public let skipped: Int
    public let blobsMissing: Int
  }
  public static let maxBytes = 256 * 1024 * 1024
  public static func write(items: [ClipItem], blobRoot: URL?, to destination: URL) throws {
    if destination.pathExtension.lowercased() != "json" {
      try DesktopZIPHistoryArchive.write(items: items, blobRoot: blobRoot, to: destination)
      return
    }
    guard items.count <= 10000 else { throw ArchiveError.tooLarge }
    let encoder = JSONEncoder()
    var data = Data("{\"version\":1,\"items\":[".utf8)
    var count = 0
    var total = 0
    for item in items
    where !item.sensitive
      && !item.payloads.contains(where: { $0.pasteboardType == SensitivityFilter.concealedType })
    {
      try DesktopZIPHistoryArchive.validateMetadata(item)
      var copy = item
      var raw: [RawPayload] = []
      var itemBytes = 0
      copy.payloads = try item.payloads.map { payload in
        let bytes = try DesktopZIPHistoryArchive.exportedBytes(payload, blobRoot: blobRoot)
        guard bytes.count <= 16 * 1024 * 1024 - itemBytes, bytes.count <= maxBytes / 2 - total
        else { throw ArchiveError.tooLarge }
        itemBytes += bytes.count
        total += bytes.count
        raw.append(.init(pasteboardType: payload.pasteboardType, data: bytes))
        return .init(pasteboardType: payload.pasteboardType, inlineData: bytes)
      }
      copy.sha256 = Hashing.sha256(of: raw)
      copy.kind = ClipKind.infer(from: raw)
      copy.preview = PreviewBuilder.build(for: raw)
      copy.sizeBytes = itemBytes
      copy.sensitivityReason = nil
      let encoded = try encoder.encode(copy)
      guard encoded.count + 3 <= maxBytes - data.count else { throw ArchiveError.tooLarge }
      if count > 0 { data.append(44) }
      data.append(encoded)
      count += 1
    }
    data.append(contentsOf: [93, 125])
    try data.write(to: destination, options: .atomic)
  }
  public static func read(from source: URL) throws -> [ClipItem] {
    try readResult(from: source).items
  }
  public static func readResult(from source: URL) throws -> ReadResult {
    let data = try boundedData(from: source, limit: maxBytes)
    if data.starts(with: [0x50, 0x4b]) { return try DesktopZIPHistoryArchive.read(data) }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1, envelope.items.count <= 10000 else {
      throw ArchiveError.invalidArchive
    }
    var validated: [ClipItem] = []
    var hashes = Set<String>()
    for item in envelope.items where !item.sensitive {
      if item.payloads.contains(where: { $0.pasteboardType == SensitivityFilter.concealedType }) {
        continue
      }
      try DesktopZIPHistoryArchive.validateMetadata(item)
      var total = 0
      let payloads = try item.payloads.map { payload -> RawPayload in
        guard payload.blobPath == nil, let inline = payload.inlineData else {
          throw ArchiveError.externalBlob
        }
        total += inline.count
        guard total <= 16 * 1024 * 1024 else { throw ArchiveError.tooLarge }
        return .init(pasteboardType: payload.pasteboardType, data: inline)
      }
      guard !payloads.isEmpty else { continue }
      var copy = item
      copy.id = UUID()
      copy.kind = ClipKind.infer(from: payloads)
      copy.preview = PreviewBuilder.build(for: payloads)
      copy.sha256 = Hashing.sha256(of: payloads)
      guard hashes.insert(copy.sha256).inserted else { continue }
      copy.sizeBytes = total
      copy.sensitivityReason = nil
      validated.append(copy)
    }
    return .init(items: validated, skipped: envelope.items.count - validated.count, blobsMissing: 0)
  }

  static func boundedData(from source: URL, limit: Int) throws -> Data {
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    guard attributes[.type] as? FileAttributeType == .typeRegular else {
      throw ArchiveError.invalidArchive
    }
    guard let size = attributes[.size] as? NSNumber, size.int64Value >= 0,
      size.int64Value <= Int64(limit)
    else { throw ArchiveError.tooLarge }
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }
    var data = Data()
    while let chunk = try handle.read(upToCount: min(64 * 1024, limit - data.count + 1)),
      !chunk.isEmpty
    {
      guard chunk.count <= limit - data.count else { throw ArchiveError.tooLarge }
      data.append(chunk)
    }
    return data
  }
}
