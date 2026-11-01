import Foundation

/// Bounded transformations between native clipboard envelopes and canonical bytes.
public enum ClipboardFormats {
  public static func windowsHTML(_ html: Data) throws -> Data {
    guard html.count <= 16 * 1024 * 1024, String(data: html, encoding: .utf8) != nil else {
      throw TextClipboardError.invalidText
    }
    let prefix = Data("<html><body><!--StartFragment-->".utf8)
    let suffix = Data("<!--EndFragment--></body></html>".utf8)
    func header(_ start: Int, _ end: Int, _ fragment: Int, _ fragmentEnd: Int) -> Data {
      Data(
        String(
          format:
            "Version:1.0\r\nStartHTML:%010d\r\nEndHTML:%010d\r\nStartFragment:%010d\r\nEndFragment:%010d\r\n",
          start, end, fragment, fragmentEnd
        ).utf8)
    }
    let start = header(0, 0, 0, 0).count
    return header(
      start, start + prefix.count + html.count + suffix.count, start + prefix.count,
      start + prefix.count + html.count) + prefix + html + suffix
  }
  public static func htmlFromWindows(_ data: Data) throws -> Data {
    guard data.count <= 16 * 1024 * 1024 else { throw TextClipboardError.tooLarge(data.count) }
    let header = String(decoding: data.prefix(4096), as: UTF8.self)
    func offset(_ field: String) -> Int? {
      guard let range = header.range(of: field + ":"),
        let line = header[range.upperBound...].split(whereSeparator: { $0.isNewline })
          .first
      else { return nil }
      return Int(line.trimmingCharacters(in: .whitespaces))
    }
    let start = offset("StartFragment") ?? offset("StartHTML")
    let end = offset("EndFragment") ?? offset("EndHTML")
    guard let start, let end, start >= 0, end >= start, end <= data.count else {
      throw TextClipboardError.invalidText
    }
    let fragment = data.subdata(in: start..<end)
    guard String(data: fragment, encoding: .utf8) != nil else {
      throw TextClipboardError.invalidText
    }
    return fragment
  }
  public static func fileURLs(from data: Data) throws -> [URL] {
    guard data.count <= 16 * 1024 * 1024, let text = String(data: data, encoding: .utf8),
      !text.contains("\0")
    else { throw TextClipboardError.invalidText }
    let lines = text.split(whereSeparator: { $0.isNewline }).filter {
      !$0.hasPrefix("#")
    }
    guard lines.count <= 4096 else { throw TextClipboardError.tooLarge(data.count) }
    return try lines.map {
      guard let url = URL(string: String($0)), url.isFileURL, !url.path.isEmpty else {
        throw TextClipboardError.invalidText
      }
      return url
    }
  }
  public static func fileURLData(_ urls: [URL]) -> Data {
    Data(urls.map(\.absoluteString).joined(separator: "\r\n").utf8)
  }
}
