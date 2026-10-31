import Foundation

/// A local lead-sentence excerpt, not a generative model or entity recognizer.
/// Input/output budgets also bound pathological combining-character sequences.
public enum DesktopLocalTextSummary {
  public static func summarize(_ text: String) -> String? {
    let bounded = DesktopTextPreview(text).text
    let cleaned = String(
      String.UnicodeScalarView(
        bounded.unicodeScalars.filter {
          $0.properties.generalCategory != .control
            || CharacterSet.whitespacesAndNewlines.contains($0)
        }))
    let normalized = cleaned.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    guard normalized.count >= 100 else { return nil }
    let characters = Array(normalized.prefix(201))
    var end: Int?
    for index in characters.indices {
      let character = characters[index]
      let terminal =
        "。！？".contains(character)
        || (".!?".contains(character)
          && (index + 1 == characters.count || characters[index + 1].isWhitespace))
      if terminal && index >= 19 && index < 200 {
        end = index + 1
        break
      }
    }
    let lead =
      end.map { String(characters.prefix($0)) }
      ?? String(normalized.prefix(normalized.count > 200 ? 199 : 200))
    let abbreviated = end == nil && normalized.count > 200
    var output = ""
    var bytes = 0
    var truncated = false
    for character in lead {
      let count = character.utf8.count
      guard count <= 2045 - bytes else {
        truncated = true
        break
      }
      output.append(character)
      bytes += count
    }
    let result = output.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !result.isEmpty else { return nil }
    return result + (abbreviated || truncated ? "…" : "")
  }
}
