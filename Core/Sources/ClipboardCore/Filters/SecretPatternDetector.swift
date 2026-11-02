import Foundation

/// Local format recognition only. Never verifies credentials, contacts providers,
/// reads copied files or returns the matching secret as a diagnostic.
enum SecretPatternDetector {
  static func isInspectableText(_ type: String) -> Bool {
    [
      "public.utf8-plain-text", "public.plain-text", "public.string", "public.text", "public.html",
      "public.rtf", "NSStringPboardType", "public.utf16-plain-text",
      "public.utf16-external-plain-text",
    ].contains(type)
  }
  private static let patterns: [NSRegularExpression] = [
    #"(?<![A-Za-z0-9_])sk-[A-Za-z0-9_-]{16,}(?![A-Za-z0-9_])"#,
    #"(?<![A-Za-z0-9_])(?:sk|rk)_(?:live|test|org)_[A-Za-z0-9_]{16,}(?![A-Za-z0-9_])"#,
    #"(?<![A-Za-z0-9_])(?:gh[pousr]_|github_pat_)[A-Za-z0-9_]{16,}(?![A-Za-z0-9_])"#,
    #"(?<![A-Za-z0-9_])glpat-[A-Za-z0-9_-]{16,}(?![A-Za-z0-9_])"#,
    #"(?<![A-Za-z0-9_])(?:xox[baprs]|xapp|xwfp)-[A-Za-z0-9-]{16,}(?![A-Za-z0-9_])"#,
    #"(?<![A-Za-z0-9_])npm_[A-Za-z0-9]{36,}(?![A-Za-z0-9_])"#,
    #"(?<![A-Za-z0-9_])whsec_[A-Za-z0-9]{16,}(?![A-Za-z0-9_])"#,
    #"(?<![A-Za-z0-9_])(?:AKIA|ASIA)[A-Z0-9]{16}(?![A-Za-z0-9_])"#,
    #"-----BEGIN (?:RSA |EC |DSA |OPENSSH |ENCRYPTED )?PRIVATE KEY-----"#,
  ].map { try! NSRegularExpression(pattern: $0) }

  static func sensitivityReason(in payloads: [RawPayload]) -> String? {
    for payload in payloads {
      switch payload.pasteboardType {
      case "public.utf8-plain-text", "public.plain-text", "public.string", "public.text",
        "public.html", "public.rtf", "NSStringPboardType":
        // Scan the complete allowed text payload, not its short UI preview.
        if matches(String(decoding: payload.data, as: UTF8.self)) { return "credentialPattern" }
      case "public.utf16-plain-text", "public.utf16-external-plain-text":
        for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
          if let text = String(data: payload.data, encoding: encoding), matches(text) {
            return "credentialPattern"
          }
        }
      default: continue
      }
    }
    // Inspect complete visible rich text with entity/RTF escaping. The UI
    // retains its own small display budgets; structural refusal masks the
    // record instead of asserting an unexamined suffix contains no secret.
    for payload in payloads where ["public.html", "public.rtf"].contains(payload.pasteboardType) {
      let inspected = RichTextPreview.sensitiveInspection(of: payload)
      if matches(inspected.text) { return "credentialPattern" }
      if inspected.isTruncated { return "uninspectableRichText" }
    }
    return nil
  }

  private static func matches(_ text: String) -> Bool {
    let range = NSRange(text.startIndex..<text.endIndex, in: text)
    return patterns.contains { $0.firstMatch(in: text, range: range) != nil }
  }
}
