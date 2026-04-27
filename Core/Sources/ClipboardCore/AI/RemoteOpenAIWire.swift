import Foundation

public enum RemoteOpenAIDecodeError: Error, Equatable {
  case malformed
  case missingChoice
  case contentEmpty
  case oversizedResponse
}

/// OpenAI Chat Completions message content. Text-only requests use
/// the bare-string form; multimodal requests use the array form with
/// typed parts. The wire JSON differs between the two — we encode
/// each variant separately rather than always emitting an array,
/// because some providers (vLLM, older self-hosted gateways) only
/// understand the string form.
public enum RemoteOpenAIContent: Codable, Equatable, Sendable {
  case text(String)
  case parts([RemoteOpenAIContentPart])

  public func encode(to encoder: Encoder) throws {
    var container = encoder.singleValueContainer()
    switch self {
    case .text(let s):
      try container.encode(s)
    case .parts(let parts):
      try container.encode(parts)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.singleValueContainer()
    if let s = try? container.decode(String.self) {
      self = .text(s)
      return
    }
    let parts = try container.decode([RemoteOpenAIContentPart].self)
    self = .parts(parts)
  }
}

public enum RemoteOpenAIContentPart: Codable, Equatable, Sendable {
  case text(String)
  case imageURL(String)

  private enum CodingKeys: String, CodingKey {
    case type
    case text
    case imageURL = "image_url"
  }

  private struct ImageURLPayload: Codable, Equatable {
    let url: String
  }

  public func encode(to encoder: Encoder) throws {
    var container = encoder.container(keyedBy: CodingKeys.self)
    switch self {
    case .text(let s):
      try container.encode("text", forKey: .type)
      try container.encode(s, forKey: .text)
    case .imageURL(let url):
      try container.encode("image_url", forKey: .type)
      try container.encode(ImageURLPayload(url: url), forKey: .imageURL)
    }
  }

  public init(from decoder: Decoder) throws {
    let container = try decoder.container(keyedBy: CodingKeys.self)
    let type = try container.decode(String.self, forKey: .type)
    switch type {
    case "text":
      let s = try container.decode(String.self, forKey: .text)
      self = .text(s)
    case "image_url":
      let payload = try container.decode(ImageURLPayload.self, forKey: .imageURL)
      self = .imageURL(payload.url)
    default:
      throw DecodingError.dataCorruptedError(
        forKey: .type,
        in: container,
        debugDescription: "unknown content part type \(type)"
      )
    }
  }
}

public struct RemoteOpenAIMessage: Codable, Equatable, Sendable {
  public var role: String
  public var content: RemoteOpenAIContent

  public init(role: String, content: RemoteOpenAIContent) {
    self.role = role
    self.content = content
  }
}

public struct RemoteOpenAIRequest: Encodable, Equatable, Sendable {
  public var model: String
  public var messages: [RemoteOpenAIMessage]
  public var maxTokens: Int?
  public var temperature: Double?

  private enum CodingKeys: String, CodingKey {
    case model
    case messages
    case maxTokens = "max_tokens"
    case temperature
  }

  public init(
    model: String,
    messages: [RemoteOpenAIMessage],
    maxTokens: Int? = nil,
    temperature: Double? = nil
  ) {
    self.model = model
    self.messages = messages
    self.maxTokens = maxTokens
    self.temperature = temperature
  }
}

public struct RemoteOpenAIResponse: Decodable, Equatable, Sendable {
  public struct Choice: Decodable, Equatable, Sendable {
    public struct Message: Decodable, Equatable, Sendable {
      public let role: String?
      public let content: String?
    }
    public let message: Message?
    public let index: Int?
  }
  public let choices: [Choice]
}

/// Base summary instruction. The language directive (when present)
/// is prepended — placing it FIRST makes small models honour it; if
/// it sits at the end, 3B-class models routinely ignore it and reply
/// in the input's language.
private let remoteSummaryInstruction: String = """
  Output exactly one short sentence (max 160 characters). \
  No bullets, no quotes, no preamble, no reasoning, no <think> \
  blocks. For very short or trivial inputs (a URL, IP, identifier, \
  filename, single word), repeat the input verbatim (truncated to \
  160 characters) instead of explaining why it can't be summarised.
  """

/// Build the full system instruction with an optional language
/// directive prepended. Language goes first because small models
/// follow front-loaded directives much more reliably.
private func remoteSummaryInstruction(language: String?) -> String {
  guard let lang = language, !lang.isEmpty else {
    return remoteSummaryInstruction
  }
  return
    "Reply in \(lang). All output must be in \(lang) regardless of "
    + "the input's language.\n\n" + remoteSummaryInstruction
}

public func decodeRemoteOpenAIResponse(_ data: Data, maxBytes: Int = 64 * 1024) throws -> String {
  guard data.count <= maxBytes else { throw RemoteOpenAIDecodeError.oversizedResponse }
  let decoded: RemoteOpenAIResponse
  do {
    decoded = try JSONDecoder().decode(RemoteOpenAIResponse.self, from: data)
  } catch {
    throw RemoteOpenAIDecodeError.malformed
  }
  guard let first = decoded.choices.first, let message = first.message else {
    throw RemoteOpenAIDecodeError.missingChoice
  }
  let raw = (message.content ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
  guard !raw.isEmpty else { throw RemoteOpenAIDecodeError.contentEmpty }
  let cleaned = stripReasoningBlocks(raw)
  guard !cleaned.isEmpty else { throw RemoteOpenAIDecodeError.contentEmpty }
  return cleaned
}

/// Strip `<think>...</think>` and `<thinking>...</thinking>` reasoning
/// blocks from a model completion. Reasoning models such as Qwen3-think
/// and DeepSeek-R1 emit chain-of-thought inside these tags at the START
/// of the response; everything after is the user-visible answer.
///
/// Strategy: strip ONLY leading reasoning blocks, and within each leading
/// block use the LAST `</think>` (not the first) as the close. Two ways
/// the previous design was wrong:
///
///   1. A non-greedy regex over the whole string would match the outer
///      `<think>` to the FIRST inner `</think>` literal in legitimate
///      content (e.g. a bullet that mentions `<think>...</think>` as a
///      concept), corrupting the answer.
///   2. An "orphan `</think>` cleanup" pass would silently delete the
///      tag from the middle of legitimate content, leaving garbage like
///      `` `) without outputting content. ``.
///
/// Greedy LAST inside the leading block prevents both. Anything past the
/// leading block — including literal `<think>` / `</think>` mentions in
/// the model's actual answer — is preserved verbatim.
///
/// Handles:
///   1. Closed leading: `<think>foo</think>bar` → `bar`.
///   2. Multiple leading: `<think>a</think><think>b</think>c` → `c`
///      (loop strips one block at a time until the head no longer opens
///      with `<think>`).
///   3. Reasoning that mentions the tag literally:
///      `<think>note about (\`<think>...</think>\`)</think>final` → `final`.
///   4. Unclosed leading (model cut off mid-thought): `<think>foo` → `""`.
///   5. Mid-content mention (no leading block):
///      `text mentioning <think>concept</think> here` → unchanged.
public func stripReasoningBlocks(_ text: String) -> String {
  var current = text.trimmingCharacters(in: .whitespacesAndNewlines)
  let pairs: [(open: String, close: String)] = [
    ("<think>", "</think>"),
    ("<thinking>", "</thinking>"),
  ]
  while true {
    var stripped = false
    for (open, close) in pairs {
      if current.lowercased().hasPrefix(open) {
        // Greedy LAST: assume the entire prefix up to the rightmost
        // `</think>` is the reasoning block. Any literal mentions
        // inside are then encapsulated inside the stripped span.
        if let closeRange = current.range(
          of: close, options: [.caseInsensitive, .backwards])
        {
          current = String(current[closeRange.upperBound...])
            .trimmingCharacters(in: .whitespacesAndNewlines)
        } else {
          // Leading open with no close — model was cut off mid-think.
          // Returning "" triggers `contentEmpty` upstream → fallback.
          current = ""
        }
        stripped = true
        break
      }
    }
    if !stripped { break }
  }
  return current
}

/// Map a Preferences `languageOverride` tag (or nil for system) to a
/// human-readable language name suitable for embedding in an English
/// LLM system prompt ("Always reply in <name>.").
///
/// Resolution order:
///   1. Explicit `tag` matches our shipped 7-language table → use the
///      curated English name (e.g. "Simplified Chinese").
///   2. Fallback for any other language code → ask Apple's Locale for
///      the English name ("fr" → "French", "ru" → "Russian", …). This
///      gives us coverage for ~150 languages without per-locale data.
///   3. System mode resolves via `Locale.current` with the same 1→2
///      fallback path; `zh` is disambiguated by script tag.
///
/// Returns nil only when the code is empty / bogus / Apple has no
/// English name for it — caller then skips the language clause.
public func remoteAIResponseLanguageName(for tag: String?) -> String? {
  // Explicit user pick.
  if let t = tag, !t.isEmpty, t != "system" {
    let normalised = normaliseTag(t)
    if let curated = languageNameTable[normalised] { return curated }
    return englishLanguageNameViaLocale(for: normalised)
  }
  // System locale — disambiguate Hans vs Hant via script tag.
  let lang = Locale.current.language
  let code = lang.languageCode?.identifier ?? ""
  if code == "zh" {
    if lang.script?.identifier == "Hant" { return "Traditional Chinese" }
    return "Simplified Chinese"
  }
  if let curated = languageNameTable[code] { return curated }
  return englishLanguageNameViaLocale(for: code)
}

/// Look up the English-locale name for an arbitrary BCP-47 code.
/// Returns nil when Apple has no name for the code (the API echoes
/// the code itself in that case, which we explicitly reject so
/// nonsense like "xx-bogus" doesn't leak into the system prompt).
private func englishLanguageNameViaLocale(for code: String) -> String? {
  guard !code.isEmpty else { return nil }
  let english = Locale(identifier: "en")
  guard let name = english.localizedString(forIdentifier: code),
    !name.isEmpty,
    name.caseInsensitiveCompare(code) != .orderedSame
  else { return nil }
  return name
}

private let languageNameTable: [String: String] = [
  "en": "English",
  "zh-Hans": "Simplified Chinese",
  "zh-Hant": "Traditional Chinese",
  "zh": "Simplified Chinese",  // explicit-`zh` falls back to Simplified
  "ja": "Japanese",
  "ko": "Korean",
  "de": "German",
  "es": "Spanish",
]

/// User-message wrapper in the *target* language. Small models follow
/// the user message's language much more strongly than they follow a
/// system-prompt directive. The wrapper also says "regardless of input
/// language" in the target language — without that reinforcement, a
/// 3B-class model still flips to English when the body is pure ASCII
/// (an IP, file path, identifier). Falls back to a generic English
/// wrapper for unknown language names.
private let userPromptByLanguage: [String: String] = [
  "English": "Summarise the following:",
  "Simplified Chinese":
    "请用简体中文总结以下内容"
    + "（无论输入是何种语言，回答必须使用简体中文）：",
  "Traditional Chinese":
    "請用繁體中文總結以下內容"
    + "（無論輸入是何種語言，回答必須使用繁體中文）：",
  "Japanese":
    "以下の内容を日本語で要約してください"
    + "（入力が何語であっても、回答は必ず日本語で）：",
  "Korean":
    "다음 내용을 한국어로 요약해 주세요"
    + " (입력이 어떤 언어든 답변은 반드시 한국어로):",
  "German":
    "Fasse das Folgende auf Deutsch zusammen"
    + " (unabhängig von der Eingabesprache muss die Antwort auf Deutsch sein):",
  "Spanish":
    "Resume lo siguiente en español"
    + " (la respuesta debe ser en español, sea cual sea el idioma de entrada):",
]

private func userPromptWrapper(language: String?) -> String {
  if let lang = language, let wrapper = userPromptByLanguage[lang] {
    return wrapper
  }
  return "Summarise the following:"
}

private func normaliseTag(_ t: String) -> String {
  // Strip region: "zh-Hans-CN" → "zh-Hans"; preserve script.
  let parts = t.split(separator: "-")
  if parts.count >= 2 {
    let head = parts[0]
    let second = parts[1]
    // If second looks like a 4-letter script (Hans/Hant/Latn) keep it.
    if second.count == 4 { return "\(head)-\(second)" }
  }
  return t
}

public func buildRemoteOpenAITextMessages(
  _ text: String,
  maxTextBytes: Int = 16 * 1024,
  responseLanguage: String? = nil
) -> [RemoteOpenAIMessage] {
  let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
  let body = truncateUTF8(trimmed, maxBytes: maxTextBytes)
  let instruction = remoteSummaryInstruction(language: responseLanguage)
  let wrapper = userPromptWrapper(language: responseLanguage)
  return [
    RemoteOpenAIMessage(role: "system", content: .text(instruction)),
    RemoteOpenAIMessage(
      role: "user",
      content: .text("\(wrapper)\n\n\(body)")
    ),
  ]
}

public func buildRemoteOpenAIImageMessages(
  _ pngOrJpeg: Data,
  mime: String,
  responseLanguage: String? = nil
) -> [RemoteOpenAIMessage] {
  let b64 = pngOrJpeg.base64EncodedString()
  let dataURI = "data:\(mime);base64,\(b64)"
  let instruction = remoteSummaryInstruction(language: responseLanguage)
  // Mirror the text path — wrapper text in the target language steers
  // small models toward responding in that language.
  let wrapper: String
  if let lang = responseLanguage {
    let imageWrappers: [String: String] = [
      "English": "Summarise this image:",
      "Simplified Chinese": "请用简体中文总结这张图片：",
      "Traditional Chinese": "請用繁體中文總結這張圖片：",
      "Japanese": "この画像を日本語で要約してください：",
      "Korean": "이 이미지를 한국어로 요약해 주세요:",
      "German": "Fasse dieses Bild auf Deutsch zusammen:",
      "Spanish": "Resume esta imagen en español:",
    ]
    wrapper = imageWrappers[lang] ?? "Summarise the following image:"
  } else {
    wrapper = "Summarise the following image:"
  }
  return [
    RemoteOpenAIMessage(role: "system", content: .text(instruction)),
    RemoteOpenAIMessage(
      role: "user",
      content: .parts([
        .text(wrapper),
        .imageURL(dataURI),
      ])
    ),
  ]
}

public func validateRemoteAIBaseURL(_ raw: String) -> URL? {
  let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
  guard !trimmed.isEmpty else { return nil }
  guard let components = URLComponents(string: trimmed) else { return nil }
  guard let rawScheme = components.scheme else { return nil }
  let scheme = rawScheme.lowercased()
  guard scheme == "http" || scheme == "https" else { return nil }
  guard let host = components.host, !host.isEmpty else { return nil }

  var rebuilt = components
  rebuilt.scheme = scheme
  if let path = rebuilt.path as String?, path.hasSuffix("/"), path != "/" {
    rebuilt.path = String(path.dropLast())
  } else if rebuilt.path == "/" {
    rebuilt.path = ""
  }
  return rebuilt.url
}

/// Parse an OpenAI-compatible error response body and return a
/// short, sanitised, human-readable message suitable for display in
/// a one-line UI label. Returns `nil` if no recognisable message can
/// be extracted (caller falls back to a generic status-code string).
///
/// Recognised shapes:
///   - OpenAI nested:  `{"error": {"message": "...", ...}}` → `error.message`
///   - Ollama nested:  `{"error": {"message": "..."}}` → `error.message`
///   - Ollama flat:    `{"error": "..."}` → `error` (string)
///   - other          → `nil`
///
/// Sanitisation: strip Unicode control scalars (preserve ASCII space),
/// collapse internal whitespace runs (incl. `\n`, `\t`) to a single
/// ASCII space, trim, and cap to `maxChars` Characters.
///
/// This function NEVER logs. The caller is responsible for ensuring
/// the returned string is shown only in user-initiated UI flows
/// (Test connection) and never written to OS Log / file logs.
public func parseRemoteOpenAIErrorBody(_ data: Data, maxChars: Int = 200) -> String? {
  guard !data.isEmpty else { return nil }
  let bounded = Data(data.prefix(2048))
  guard let obj = try? JSONSerialization.jsonObject(with: bounded, options: []) else {
    return nil
  }
  guard let dict = obj as? [String: Any] else { return nil }
  let raw: String?
  if let nested = dict["error"] as? [String: Any],
    let message = nested["message"] as? String
  {
    raw = message
  } else if let flat = dict["error"] as? String {
    raw = flat
  } else {
    raw = nil
  }
  guard let raw else { return nil }

  // Strip Unicode control scalars (covers C0 < 0x20, DEL 0x7F, and C1
  // 0x80..<0xA0 + bidi format chars), but keep ASCII space. Unicode
  // general category .control covers C0/C1/DEL; .format covers bidi
  // and other invisible formatting controls — both should be stripped
  // before the result lands in a single-line SwiftUI Text label.
  let stripped = String(
    String.UnicodeScalarView(
      raw.unicodeScalars.filter { scalar in
        if scalar == " " { return true }
        let category = scalar.properties.generalCategory
        return category != .control && category != .format
      }
    )
  )

  // Collapse any whitespace runs (post-strip — the strip already
  // removed `\n` / `\t` since they are control chars) to a single
  // ASCII space. Defensive against U+00A0 etc.
  var collapsed = ""
  collapsed.reserveCapacity(stripped.count)
  var lastWasSpace = false
  for ch in stripped {
    if ch.isWhitespace {
      if !lastWasSpace {
        collapsed.append(" ")
        lastWasSpace = true
      }
    } else {
      collapsed.append(ch)
      lastWasSpace = false
    }
  }

  let trimmed = collapsed.trimmingCharacters(in: .whitespacesAndNewlines)
  if trimmed.isEmpty { return nil }
  return String(trimmed.prefix(maxChars))
}

/// Truncate `s` so the UTF-8 representation is at most `maxBytes`,
/// stopping at a Character boundary (so we never split a grapheme),
/// and append a `[truncated]` sentinel only when truncation occurred.
/// The sentinel itself is inside the returned string but not
/// counted against `maxBytes`.
private func truncateUTF8(_ s: String, maxBytes: Int) -> String {
  let utf8Count = s.utf8.count
  if utf8Count <= maxBytes { return s }
  var running = 0
  var endIndex = s.startIndex
  for index in s.indices {
    let charBytes = s[index].utf8.count
    if running + charBytes > maxBytes { break }
    running += charBytes
    endIndex = s.index(after: index)
  }
  return String(s[..<endIndex]) + " [truncated]"
}
