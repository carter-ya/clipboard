import Foundation

#if os(Windows)
  import WinSDK
#endif

/// Shared system message languages for desktop controls and local analysis.
public enum DesktopLanguagePreferences {
  // A session's display language is stable. Resolving it for every label used
  // to enumerate the process environment / query Foundation during layout.
  public static let preferredLanguages: [String] = {
    #if os(Linux)
      // Linux Foundation can return en-001 even when a desktop locale is set.
      return linuxPreferredLanguages(
        environment: ProcessInfo.processInfo.environment, fallback: Locale.preferredLanguages)
    #elseif os(Windows)
      var count: ULONG = 0
      var length: ULONG = 0
      if GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, nil, &length),
        length > 1, length <= 65536
      {
        var buffer = [WCHAR](repeating: 0, count: Int(length))
        if GetUserPreferredUILanguages(DWORD(MUI_LANGUAGE_NAME), &count, &buffer, &length) {
          let languages = windowsPreferredLanguages(buffer: buffer)
          if !languages.isEmpty { return languages }
        }
      }
      return Locale.preferredLanguages
    #else
      return Locale.preferredLanguages
    #endif
  }()

  /// Windows returns UTF-16 language names separated and terminated by NULs.
  static func windowsPreferredLanguages(buffer: [UInt16]) -> [String] {
    var result: [String] = []
    var start = 0
    for end in buffer.indices where buffer[end] == 0 {
      guard end > start else { break }
      if let tag = normalizedTag(String(decoding: buffer[start..<end], as: UTF16.self)),
        !result.contains(tag)
      {
        result.append(tag)
      }
      start = end + 1
    }
    return result
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
