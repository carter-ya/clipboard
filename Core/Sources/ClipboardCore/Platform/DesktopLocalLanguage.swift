import Foundation

public enum DesktopLocalLanguageTask: String, Codable, Sendable {
  case summary
  case enrichment
}

public protocol DesktopLocalLanguageProcessing: Sendable {
  func process(text: String, task: DesktopLocalLanguageTask, language: String?) async throws
    -> DesktopLocalLanguageOutput
}

public struct DesktopLocalLanguageResult: Equatable, Sendable {
  public let text: String
  public let task: DesktopLocalLanguageTask
  public let inputTruncated: Bool
  public init(text: String, task: DesktopLocalLanguageTask, inputTruncated: Bool) {
    self.text = text
    self.task = task
    self.inputTruncated = inputTruncated
  }
}

/// Typed, bounded output from an offline language worker. The model's proposed
/// entities are checked against the original input before they can be displayed.
public struct DesktopLocalLanguageOutput: Equatable, Sendable {
  public let task: DesktopLocalLanguageTask
  public let summary: String?
  public let languageCode: String?
  public let entities: [String]
  public let inputTruncated: Bool

  public init(
    task: DesktopLocalLanguageTask, summary: String? = nil, languageCode: String? = nil,
    entities: [String] = [], inputTruncated: Bool = false
  ) throws {
    guard entities.count <= 5,
      entities.allSatisfy({
        !$0.isEmpty && $0.count <= 128 && $0.utf8.count <= 512
          && $0 == $0.trimmingCharacters(in: .whitespacesAndNewlines)
          && !$0.unicodeScalars.contains(where: { $0.properties.generalCategory == .control })
      })
    else { throw DesktopServiceError.invalidValue }
    if let languageCode {
      guard (2...3).contains(languageCode.utf8.count),
        languageCode.utf8.allSatisfy({ (97...122).contains($0) })
      else { throw DesktopServiceError.invalidValue }
    }
    let normalized: String?
    switch task {
    case .summary:
      guard let summary, summary.utf8.count <= 2048, languageCode == nil, entities.isEmpty,
        !summary.unicodeScalars.contains(where: {
          $0.properties.generalCategory == .control
            && !CharacterSet.whitespacesAndNewlines.contains($0)
        })
      else { throw DesktopServiceError.invalidValue }
      let cleaned = stripReasoningBlocks(summary)
        .split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
      guard !cleaned.isEmpty else { throw DesktopServiceError.invalidValue }
      normalized = String(cleaned.prefix(200))
    case .enrichment:
      guard summary == nil else { throw DesktopServiceError.invalidValue }
      normalized = nil
    }
    self.task = task
    self.summary = normalized
    self.languageCode = languageCode == "und" ? nil : languageCode
    self.entities = entities
    self.inputTruncated = inputTruncated
  }

  public init(workerOutput: Data) throws {
    struct Wire: Decodable {
      let task: DesktopLocalLanguageTask
      let summary: String?
      let language: String?
      let entities: [String]
      let inputTruncated: Bool
    }
    guard !workerOutput.isEmpty, workerOutput.count <= 4096 else {
      throw DesktopServiceError.tooLarge
    }
    let wire: Wire
    do { wire = try JSONDecoder().decode(Wire.self, from: workerOutput) } catch {
      throw DesktopServiceError.invalidValue
    }
    try self.init(
      task: wire.task, summary: wire.summary, languageCode: wire.language,
      entities: wire.entities, inputTruncated: wire.inputTruncated)
  }

  public func renderedText(for input: String, language: String? = nil) throws -> String {
    if let summary { return summary }
    var found: [String] = []
    var seen: Set<String> = []
    for candidate in entities {
      guard
        let range = input.range(of: candidate, options: [.caseInsensitive, .diacriticInsensitive])
      else { continue }
      let original = String(input[range])
      if seen.insert(original.lowercased()).inserted { found.append(original) }
    }
    let content: String
    if found.isEmpty {
      guard let lead = DesktopLocalTextSummary.summarize(input) else {
        throw DesktopServiceError.invalidValue
      }
      content = String(lead.prefix(120)) + (lead.count > 120 ? "…" : "")
    } else {
      content = found.joined(separator: ", ")
    }
    let locale =
      language.map(Locale.init(identifier:))
      ?? Locale(identifier: DesktopUILanguage.resolve(override: nil).rawValue)
    let name = languageCode.flatMap { locale.localizedString(forLanguageCode: $0) }
    let result = name.map { $0 + " · " + content } ?? content
    return String(DesktopTextPreview(result, maxUTF8Bytes: 2048).text.prefix(200))
  }
}
