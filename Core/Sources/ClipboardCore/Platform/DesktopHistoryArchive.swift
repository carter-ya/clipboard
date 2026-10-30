import Foundation

/// A self-contained JSON archive: no platform shell commands or extracted paths.
/// Only non-sensitive history is included; all blob bytes are resolved in memory.
public enum DesktopHistoryArchive {
  public enum ArchiveError: Error { case tooLarge, invalidArchive, externalBlob }
  private struct Envelope: Codable {
    var version = 1
    var items: [ClipItem]
  }
  public static let maxBytes = 256 * 1024 * 1024
  public static func write(items: [ClipItem], blobRoot: URL?, to destination: URL) throws {
    let resolver = PayloadResolver(blobRoot: blobRoot)
    var exported: [ClipItem] = []
    var total = 0
    for item in items where !item.sensitive {
      var copy = item
      copy.payloads = try item.payloads.map { payload in
        let data = try resolver.data(for: payload)
        total += data.count
        guard total <= maxBytes / 2 else { throw ArchiveError.tooLarge }
        return .init(pasteboardType: payload.pasteboardType, inlineData: data)
      }
      exported.append(copy)
    }
    let data = try JSONEncoder().encode(Envelope(items: exported))
    guard data.count <= maxBytes else { throw ArchiveError.tooLarge }
    try data.write(to: destination, options: .atomic)
  }
  public static func read(from source: URL) throws -> [ClipItem] {
    let attributes = try FileManager.default.attributesOfItem(atPath: source.path)
    guard let size = attributes[.size] as? NSNumber, size.intValue <= maxBytes else {
      throw ArchiveError.tooLarge
    }
    let handle = try FileHandle(forReadingFrom: source)
    defer { try? handle.close() }
    let data = try handle.read(upToCount: maxBytes + 1) ?? Data()
    guard data.count <= maxBytes else { throw ArchiveError.tooLarge }
    let envelope = try JSONDecoder().decode(Envelope.self, from: data)
    guard envelope.version == 1, envelope.items.count <= 10000 else {
      throw ArchiveError.invalidArchive
    }
    var validated: [ClipItem] = []
    for item in envelope.items where !item.sensitive {
      if item.payloads.contains(where: { $0.pasteboardType == SensitivityFilter.concealedType }) {
        continue
      }
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
      copy.sizeBytes = total
      copy.sensitivityReason = nil
      validated.append(copy)
    }
    return validated
  }
}
