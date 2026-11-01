import Foundation

/// Shared system message languages for desktop controls and local analysis.
public enum DesktopLanguagePreferences {
  public static var preferredLanguages: [String] {
    #if os(Linux)
      // Linux Foundation can return en-001 even when a desktop locale is set.
      return linuxPreferredLanguages(
        environment: ProcessInfo.processInfo.environment, fallback: Locale.preferredLanguages)
    #else
      return Locale.preferredLanguages
    #endif
  }

  /// GNU message-locale precedence, with normalized language tags for callers.
  public static func linuxPreferredLanguages(
    environment: [String: String], fallback: [String]
  ) -> [String] {
    let locale = ["LC_ALL", "LC_MESSAGES", "LANG"].compactMap { key -> String? in
      guard let value = environment[key]?.trimmingCharacters(in: .whitespacesAndNewlines),
        !value.isEmpty
      else { return nil }
      return value
    }.first
    guard let locale else { return fallback }
    let localeTag = normalizedTag(locale)
    // The C/POSIX message locale disables a LANGUAGE priority list.
    if localeTag == "c" || localeTag == "posix" { return ["en"] }
    var languages: [String] = []
    if let priority = environment["LANGUAGE"] {
      for part in priority.split(separator: ":", maxSplits: 16).prefix(16) {
        if let normalized = normalizedTag(String(part)) {
          let tag = normalized == "c" || normalized == "posix" ? "en" : normalized
          if !languages.contains(tag) { languages.append(tag) }
        }
      }
    }
    if !languages.isEmpty { return languages }
    return localeTag.map { [$0] } ?? fallback
  }

  private static func normalizedTag(_ raw: String) -> String? {
    let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
    guard !value.isEmpty, value.utf8.count <= 256 else { return nil }
    let name = value.split(separator: "@", maxSplits: 1).first?
      .split(separator: ".", maxSplits: 1).first
    guard let name, !name.isEmpty else { return nil }
    let tag = name.replacingOccurrences(of: "_", with: "-").lowercased()
    guard let first = tag.utf8.first, (97...122).contains(first),
      !tag.split(separator: "-", omittingEmptySubsequences: false).contains(where: { $0.isEmpty }),
      tag.utf8.allSatisfy({
        (97...122).contains($0) || (48...57).contains($0) || $0 == 45
      })
    else { return nil }
    return tag
  }
}
