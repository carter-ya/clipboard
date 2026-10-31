import Foundation

public enum DesktopUILanguage: String, CaseIterable, Sendable {
  case english = "en"
  case simplifiedChinese = "zh-Hans"
  case traditionalChinese = "zh-Hant"
  case japanese = "ja"
  case korean = "ko"
  case german = "de"
  case spanish = "es"

  public var nativeName: String {
    switch self {
    case .english: return "English"
    case .simplifiedChinese: return "简体中文"
    case .traditionalChinese: return "繁體中文"
    case .japanese: return "日本語"
    case .korean: return "한국어"
    case .german: return "Deutsch"
    case .spanish: return "Español"
    }
  }

  /// Stable indices shared with the native shell's static label tables.
  public var shellIndex: Int32 {
    switch self {
    case .english: return 0
    case .simplifiedChinese: return 1
    case .traditionalChinese: return 2
    case .japanese: return 3
    case .korean: return 4
    case .german: return 5
    case .spanish: return 6
    }
  }

  public static func resolve(
    override: String?, preferredLanguages: [String] = Locale.preferredLanguages
  ) -> Self {
    let candidates = override.map { [$0] } ?? preferredLanguages
    for candidate in candidates {
      let parts = candidate.replacingOccurrences(of: "_", with: "-").lowercased().split(
        separator: "-")
      guard let base = parts.first else { continue }
      switch base {
      case "en": return .english
      case "ja": return .japanese
      case "ko": return .korean
      case "de": return .german
      case "es": return .spanish
      case "zh":
        if parts.contains("hant") { return .traditionalChinese }
        if parts.contains("hans") { return .simplifiedChinese }
        return parts.contains(where: { ["tw", "hk", "mo"].contains($0) })
          ? .traditionalChinese : .simplifiedChinese
      default: continue
      }
    }
    return .english
  }
}

public enum DesktopStringCatalog {
  static let tables: [String: [String: String]] = {
    guard let url = Bundle.module.url(forResource: "DesktopStrings", withExtension: "json"),
      let data = try? Data(contentsOf: url),
      let result = try? JSONDecoder().decode([String: [String: String]].self, from: data)
    else { return [:] }
    return result
  }()

  public static func text(
    _ value: String, language: String?, preferredLanguages: [String] = Locale.preferredLanguages
  ) -> String {
    let resolved = DesktopUILanguage.resolve(
      override: language, preferredLanguages: preferredLanguages)
    let table = tables[resolved.rawValue] ?? [:]
    if value.hasSuffix(" items"), let count = Int(value.dropLast(6)), count >= 0 {
      return (table["{count} items"] ?? "{count} items")
        .replacingOccurrences(of: "{count}", with: String(count))
    }
    let parts = value.split(separator: " ")
    if parts.count == 4, parts[0] == "Image", parts[1] == "·", parts[3] == "bytes",
      let bytes = Int(parts[2]), bytes >= 0
    {
      let key = "Image · {bytes} bytes"
      return (table[key] ?? key).replacingOccurrences(of: "{bytes}", with: String(bytes))
    }
    if parts.count == 6, parts[0] == "Imported", parts[2] == "items;",
      parts[4] == "duplicates", parts[5] == "skipped.",
      let added = Int(parts[1]), added >= 0, let skipped = Int(parts[3]), skipped >= 0
    {
      let key = "Imported {added} items; {skipped} duplicates skipped."
      return (table[key] ?? key).replacingOccurrences(of: "{added}", with: String(added))
        .replacingOccurrences(of: "{skipped}", with: String(skipped))
    }
    return table[value] ?? value
  }
}
