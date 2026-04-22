import Foundation
import NaturalLanguage

/// Baseline on-device text summarizer using the NaturalLanguage
/// framework: detects the dominant language and extracts named
/// entities (people, places, organizations). Not an LLM — just a
/// fast, battery-cheap enrichment that works everywhere we ship
/// (macOS 13+). Foundation Models in S66 will supersede this when
/// available.
///
/// Output shape examples:
///   "English · Apple Inc., Tim Cook, Tokyo"
///   "日本語 · Sony, 東京"
///   "English"                            (no entities found)
///   nil                                  (text too short to bother)
struct NaturalLanguageTextSummarizer: Sendable {
  private static let minTextLength = 100
  private static let maxEntities = 5

  func summarize(text: String) async -> String? {
    let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
    guard trimmed.count >= Self.minTextLength else { return nil }

    return await withCheckedContinuation { continuation in
      DispatchQueue.global(qos: .utility).async {
        let language = Self.primaryLanguageName(for: trimmed)
        let entities = Self.namedEntities(in: trimmed)

        var parts: [String] = []
        if let language { parts.append(language) }
        if !entities.isEmpty {
          parts.append(entities.joined(separator: ", "))
        }

        if parts.isEmpty {
          continuation.resume(returning: nil)
        } else {
          continuation.resume(returning: parts.joined(separator: " · "))
        }
      }
    }
  }

  private static func primaryLanguageName(for text: String) -> String? {
    let recognizer = NLLanguageRecognizer()
    recognizer.processString(text)
    guard let language = recognizer.dominantLanguage else { return nil }
    // Prefer the user's locale when formatting the language name, so
    // a Chinese user sees "英语" rather than "English".
    let locale = Locale.current
    return locale.localizedString(forLanguageCode: language.rawValue) ?? language.rawValue
  }

  private static func namedEntities(in text: String) -> [String] {
    let tagger = NLTagger(tagSchemes: [.nameType])
    tagger.string = text
    let options: NLTagger.Options = [.omitPunctuation, .omitWhitespace, .joinNames]
    let wanted: Set<NLTag> = [.personalName, .placeName, .organizationName]

    var results: [String] = []
    var seen: Set<String> = []
    tagger.enumerateTags(
      in: text.startIndex..<text.endIndex,
      unit: .word,
      scheme: .nameType,
      options: options
    ) { tag, range in
      guard let tag, wanted.contains(tag) else { return true }
      let token = String(text[range]).trimmingCharacters(in: .whitespacesAndNewlines)
      guard !token.isEmpty else { return true }
      if seen.insert(token).inserted {
        results.append(token)
        if results.count >= maxEntities {
          return false
        }
      }
      return true
    }
    return results
  }
}
