#if os(Linux) || os(Windows)
  import Foundation

  /// Independent minimal PDF writer for private fixtures, never user content.
  func syntheticPDFText(_ text: String, pages: Int = 1) -> Data {
    let escaped = text.replacingOccurrences(of: "\\", with: "\\\\")
      .replacingOccurrences(of: "(", with: "\\(")
      .replacingOccurrences(of: ")", with: "\\)")
    let stream = "BT /F1 12 Tf 30 740 Td (" + escaped + ") Tj ET"
    let objects = [
      "<< /Type /Catalog /Pages 2 0 R >>",
      "<< /Type /Pages /Kids [" + String(repeating: "3 0 R ", count: pages)
        + "] /Count \(pages) >>",
      "<< /Type /Page /Parent 2 0 R /MediaBox [0 0 612 792] /Resources << /Font << /F1 4 0 R >> >> /Contents 5 0 R >>",
      "<< /Type /Font /Subtype /Type1 /BaseFont /Helvetica >>",
      "<< /Length \(stream.utf8.count) >>\nstream\n" + stream + "\nendstream",
    ]
    var result = Data("%PDF-1.4\n".utf8)
    var offsets: [Int] = []
    for (index, object) in objects.enumerated() {
      offsets.append(result.count)
      result.append(Data("\(index + 1) 0 obj\n\(object)\nendobj\n".utf8))
    }
    let start = result.count
    result.append(Data("xref\n0 6\n0000000000 65535 f \n".utf8))
    for offset in offsets {
      let digits = String(offset)
      result.append(
        Data((String(repeating: "0", count: 10 - digits.count) + digits + " 00000 n \n").utf8))
    }
    result.append(Data("trailer\n<< /Size 6 /Root 1 0 R >>\nstartxref\n\(start)\n%%EOF\n".utf8))
    return result
  }
#endif
