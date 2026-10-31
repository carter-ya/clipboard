import Foundation

public struct DesktopItemPresentation: Equatable, Sendable {
  public let rowText: String?
  public let createdText: String
  public let sourceName: String?
}

/// Display-only metadata. Build one localized formatter per batch, away from UI;
/// never resolve payloads, query applications, stat files or modify clip data.
public enum DesktopHistoryPresentation {
  public static func make(
    items: [ClipItem], language: String?, timeZone: TimeZone = .current
  ) -> [UUID: DesktopItemPresentation] {
    guard !Task.isCancelled else { return [:] }
    let formatter = DateFormatter()
    formatter.locale = Locale(identifier: DesktopUILanguage.resolve(override: language).rawValue)
    formatter.calendar = Calendar(identifier: .gregorian)
    formatter.timeZone = timeZone
    formatter.dateStyle = .medium
    formatter.timeStyle = .short
    var result: [UUID: DesktopItemPresentation] = [:]
    for item in items {
      if Task.isCancelled { break }
      var row: String?
      if !item.sensitive {
        let summary =
          item.kind == .image
          ? item.summary.map { displayLine($0, maxBytes: 512) } : nil
        row =
          summary.flatMap { $0.isEmpty ? nil : $0 }
          ?? displayLine(item.preview, maxBytes: 512)
      }
      let seconds = item.createdAt.timeIntervalSince1970
      let validDate = seconds.isFinite && (-62_135_596_800...253_402_300_799).contains(seconds)
      let date = validDate ? formatter.string(from: item.createdAt) : ""
      result[item.id] = .init(
        rowText: row, createdText: date.isEmpty ? "—" : date,
        sourceName: sourceName(item.sourceBundleID))
    }
    return result
  }
  public static func sourceName(_ identifier: String?) -> String? {
    guard let identifier, !identifier.isEmpty else { return nil }
    let bounded = DesktopTextPreview(identifier, maxUTF8Bytes: 4096).text
    let label: String
    if bounded.lowercased().hasPrefix("windows:") {
      let value = String(bounded.dropFirst(8)).replacingOccurrences(of: "\\", with: "/")
      label = value.split(separator: "/").last.map(String.init) ?? value
    } else if bounded.hasPrefix("linux:") {
      label = String(bounded.dropFirst(6))
    } else {
      label = bounded
    }
    let clean = displayLine(label, maxBytes: 256)
    return clean.isEmpty ? nil : clean
  }
  fileprivate static func displayLine(_ value: String, maxBytes: Int) -> String {
    let bounded = DesktopTextPreview(value, maxUTF8Bytes: maxBytes).text
    let clean = String(
      String.UnicodeScalarView(
        bounded.unicodeScalars.map {
          $0.properties.generalCategory == .control ? Unicode.Scalar(32) : $0
        }))
    return clean.split(whereSeparator: \.isWhitespace).joined(separator: " ")
  }
}

/// File names/paths come only from copied references, with no file-system access.
/// The original URL bytes remain the sole source for actual native Copy.
public struct DesktopFileReferencePreview: Equatable, Sendable {
  public struct Entry: Equatable, Sendable {
    public let name: String
    public let path: String
  }
  public let entries: [Entry]
  public let totalCount: Int
  public let isTruncated: Bool
  public init(data: Data, maxEntries: Int = 128, maxUTF8Bytes: Int = 64 * 1024) throws {
    guard (0...4096).contains(maxEntries), (0...(64 * 1024)).contains(maxUTF8Bytes) else {
      throw TextClipboardError.invalidText
    }
    let urls = try ClipboardFormats.fileURLs(from: data)
    guard !urls.isEmpty else { throw TextClipboardError.invalidText }
    totalCount = urls.count
    var entries: [Entry] = []
    var bytes = 0
    var shortened = false
    for url in urls {
      let name = url.lastPathComponent.isEmpty ? url.path : url.lastPathComponent
      let path =
        (url.host.map { $0.isEmpty || $0 == "localhost" ? "" : "//" + $0 } ?? "") + url.path
      let namePreview = DesktopTextPreview(name, maxUTF8Bytes: 512)
      let pathPreview = DesktopTextPreview(path, maxUTF8Bytes: 4096)
      let entry = Entry(
        name: DesktopHistoryPresentation.displayLine(namePreview.text, maxBytes: 512),
        path: DesktopHistoryPresentation.displayLine(pathPreview.text, maxBytes: 4096))
      let size = entry.name.utf8.count + entry.path.utf8.count
      guard entries.count < maxEntries, size <= maxUTF8Bytes - bytes else { break }
      entries.append(entry)
      bytes += size
      shortened = shortened || namePreview.isTruncated || pathPreview.isTruncated
    }
    self.entries = entries
    isTruncated = shortened || entries.count < totalCount
  }
}
