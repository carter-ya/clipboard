import XCTest

@testable import ClipboardCore

final class RemoteOpenAIWireTests: XCTestCase {
  // MARK: - validateRemoteAIBaseURL

  func testValidatorAcceptsHTTP() {
    let url = validateRemoteAIBaseURL("http://localhost:11434/v1")
    XCTAssertNotNil(url)
    XCTAssertEqual(url?.scheme, "http")
    XCTAssertEqual(url?.host, "localhost")
  }

  func testValidatorAcceptsHTTPS() {
    let url = validateRemoteAIBaseURL("https://api.openai.com/v1")
    XCTAssertEqual(url?.absoluteString, "https://api.openai.com/v1")
  }

  func testValidatorAcceptsMixedCaseScheme() {
    let url = validateRemoteAIBaseURL("HTTPS://api.openai.com/v1")
    XCTAssertEqual(url?.scheme, "https")
    XCTAssertEqual(url?.host, "api.openai.com")
  }

  // localhost:11434 with no scheme parses as scheme="localhost", which
  // we must reject — otherwise users who paste a host:port end up with
  // garbage URLs.
  func testValidatorRejectsBareHostPort() {
    XCTAssertNil(validateRemoteAIBaseURL("localhost:11434"))
  }

  func testValidatorRejectsSSHScheme() {
    XCTAssertNil(validateRemoteAIBaseURL("ssh://example.com"))
  }

  func testValidatorRejectsFileScheme() {
    XCTAssertNil(validateRemoteAIBaseURL("file:///etc/passwd"))
  }

  func testValidatorRejectsEmpty() {
    XCTAssertNil(validateRemoteAIBaseURL(""))
    XCTAssertNil(validateRemoteAIBaseURL("   "))
  }

  func testValidatorRejectsHTTPSWithoutHost() {
    XCTAssertNil(validateRemoteAIBaseURL("https://"))
  }

  func testValidatorStripsTrailingSlash() {
    let url = validateRemoteAIBaseURL("https://api.openai.com/v1/")
    XCTAssertEqual(url?.absoluteString, "https://api.openai.com/v1")
  }

  func testValidatorPreservesSingleRootSlash() {
    let url = validateRemoteAIBaseURL("https://api.openai.com/")
    XCTAssertEqual(url?.absoluteString, "https://api.openai.com")
  }

  // MARK: - decodeRemoteOpenAIResponse

  func testDecoderHappyPath() throws {
    let json = #"""
      {
        "choices": [
          { "index": 0, "message": { "role": "assistant", "content": "  hello world  " } }
        ]
      }
      """#
    let result = try decodeRemoteOpenAIResponse(Data(json.utf8))
    XCTAssertEqual(result, "hello world")
  }

  func testDecoderRejectsMalformedJSON() {
    let bad = Data("not json".utf8)
    XCTAssertThrowsError(try decodeRemoteOpenAIResponse(bad)) { error in
      XCTAssertEqual(error as? RemoteOpenAIDecodeError, .malformed)
    }
  }

  func testDecoderRejectsMissingChoice() {
    let json = Data(#"{ "choices": [] }"#.utf8)
    XCTAssertThrowsError(try decodeRemoteOpenAIResponse(json)) { error in
      XCTAssertEqual(error as? RemoteOpenAIDecodeError, .missingChoice)
    }
  }

  func testDecoderRejectsEmptyContent() {
    let json = Data(#"{ "choices": [ { "message": { "content": "   " } } ] }"#.utf8)
    XCTAssertThrowsError(try decodeRemoteOpenAIResponse(json)) { error in
      XCTAssertEqual(error as? RemoteOpenAIDecodeError, .contentEmpty)
    }
  }

  func testDecoderRejectsOversized() {
    let body = String(repeating: "a", count: 32)
    let data = Data(body.utf8)
    XCTAssertThrowsError(try decodeRemoteOpenAIResponse(data, maxBytes: 10)) { error in
      XCTAssertEqual(error as? RemoteOpenAIDecodeError, .oversizedResponse)
    }
  }

  // MARK: - buildRemoteOpenAITextMessages

  func testTextMessagesShortNoTruncation() {
    let messages = buildRemoteOpenAITextMessages("hello world")
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0].role, "system")
    XCTAssertEqual(messages[1].role, "user")
    if case .text(let userText) = messages[1].content {
      XCTAssertTrue(userText.contains("hello world"))
      XCTAssertFalse(userText.contains("[truncated]"))
    } else {
      XCTFail("expected text content")
    }
  }

  func testTextMessagesLongTruncated() {
    let body = String(repeating: "x", count: 200)
    let messages = buildRemoteOpenAITextMessages(body, maxTextBytes: 50)
    if case .text(let userText) = messages[1].content {
      XCTAssertTrue(userText.contains("[truncated]"))
      // Body section after the prompt header should be at most 50 bytes
      // of original content; we don't check exact length but verify
      // the original 200-char run got chopped.
      XCTAssertFalse(userText.contains(String(repeating: "x", count: 200)))
    } else {
      XCTFail("expected text content")
    }
  }

  func testTextMessagesUTF8BoundarySafe() {
    let body = String(repeating: "中", count: 50)  // each is 3 UTF-8 bytes
    let messages = buildRemoteOpenAITextMessages(body, maxTextBytes: 10)
    if case .text(let userText) = messages[1].content {
      XCTAssertTrue(userText.contains("[truncated]"))
      // No replacement char or splice mid-codepoint.
      XCTAssertFalse(userText.contains("\u{FFFD}"))
    } else {
      XCTFail("expected text content")
    }
  }

  // MARK: - buildRemoteOpenAIImageMessages

  func testImageMessagesEmitsDataURI() throws {
    let png = Data([0x89, 0x50, 0x4E, 0x47])
    let messages = buildRemoteOpenAIImageMessages(png, mime: "image/png")
    XCTAssertEqual(messages.count, 2)
    XCTAssertEqual(messages[0].role, "system")
    guard case .parts(let parts) = messages[1].content else {
      return XCTFail("expected parts content")
    }
    XCTAssertEqual(parts.count, 2)
    if case .imageURL(let uri) = parts[1] {
      XCTAssertTrue(uri.hasPrefix("data:image/png;base64,"))
    } else {
      XCTFail("expected image url part")
    }
  }

  func testRequestEncodesTextOnlyContentAsString() throws {
    let req = RemoteOpenAIRequest(
      model: "gpt-4o-mini",
      messages: [RemoteOpenAIMessage(role: "user", content: .text("hi"))]
    )
    let data = try JSONEncoder().encode(req)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssertTrue(json.contains(#""content":"hi""#))
  }

  // MARK: - parseRemoteOpenAIErrorBody

  func testParseErrorOpenAINestedShape() {
    let json = #"""
      {"error": {"message": "Invalid API key", "type": "invalid_request_error", "code": "invalid_api_key"}}
      """#
    let result = parseRemoteOpenAIErrorBody(Data(json.utf8))
    XCTAssertEqual(result, "Invalid API key")
  }

  func testParseErrorOllamaFlatString() {
    let json = #"""
      {"error": "  model 'gpt-fake' not found  "}
      """#
    let result = parseRemoteOpenAIErrorBody(Data(json.utf8))
    XCTAssertEqual(result, "model 'gpt-fake' not found")
  }

  func testParseErrorOllamaNestedShape() {
    let json = #"""
      {"error": {"message": "out of memory"}}
      """#
    let result = parseRemoteOpenAIErrorBody(Data(json.utf8))
    XCTAssertEqual(result, "out of memory")
  }

  func testParseErrorReturnsNilForNonJSON() {
    let html = "<html><body><h1>404 Not Found</h1></body></html>"
    XCTAssertNil(parseRemoteOpenAIErrorBody(Data(html.utf8)))
  }

  func testParseErrorReturnsNilForEmpty() {
    XCTAssertNil(parseRemoteOpenAIErrorBody(Data()))
  }

  func testParseErrorSanitisesControlChars() {
    // Mix of control chars (\n, \t, ESC 0x1B) and ASCII spaces. The
    // implementation strips control scalars outright and then
    // collapses runs of whitespace into a single ASCII space; trim
    // removes leading/trailing whitespace.
    let json = "{\"error\":\"  a\\nb\\u001B  c \\t d  \"}"
    let result = parseRemoteOpenAIErrorBody(Data(json.utf8))
    XCTAssertNotNil(result)
    XCTAssertFalse(result?.contains("\n") ?? true)
    XCTAssertFalse(result?.contains("\t") ?? true)
    XCTAssertFalse(result?.contains("\u{1B}") ?? true)
    // \n is a control → stripped (a + b adjacent); ESC stripped (b + spaces);
    // surrounding spaces collapse to single space; outer trim removes both ends.
    XCTAssertEqual(result, "ab c d")
  }

  func testParseErrorTruncatesLongMessageTo200() {
    let longMessage = String(repeating: "x", count: 500)
    let json = "{\"error\":{\"message\":\"\(longMessage)\"}}"
    // Pad with garbage past 2 KiB to verify the prefix(2048) cap still
    // lets a valid message inside the first 2 KiB through cleanly.
    let padded = json + String(repeating: " ", count: 4096)
    let result = parseRemoteOpenAIErrorBody(Data(padded.utf8))
    XCTAssertNotNil(result)
    XCTAssertEqual(result?.count, 200)
    XCTAssertEqual(result, String(repeating: "x", count: 200))
  }

  // MARK: - stripReasoningBlocks

  func testStripReasoningPlainTextUnchanged() {
    XCTAssertEqual(stripReasoningBlocks("hello world"), "hello world")
  }

  func testStripReasoningSimpleBlock() {
    XCTAssertEqual(stripReasoningBlocks("<think>foo</think>bar"), "bar")
  }

  func testStripReasoningCaseAndNewlines() {
    XCTAssertEqual(
      stripReasoningBlocks("<THINKING>foo</THINKING>\nbar"),
      "bar"
    )
  }

  func testStripReasoningMultipleBlocks() {
    XCTAssertEqual(
      stripReasoningBlocks("<think>foo</think><think>baz</think>final"),
      "final"
    )
  }

  func testStripReasoningUnclosedTag() {
    XCTAssertEqual(stripReasoningBlocks("<think>foo bar baz"), "")
  }

  func testStripReasoningPureBlock() {
    XCTAssertEqual(stripReasoningBlocks("<think>only</think>"), "")
  }

  func testStripReasoningNestedHandledByGreedyLast() {
    // Greedy LAST: leading `<think>` matches up to the rightmost
    // `</think>` (consuming the inner literal mention along with the
    // outer block), yielding `final`.
    XCTAssertEqual(
      stripReasoningBlocks("<think>outer<think>inner</think>tail</think>final"),
      "final"
    )
  }

  func testStripReasoningPreservesMidContentMentions() {
    // No leading `<think>` open — mid-content tag mentions in the
    // model's actual answer must survive unchanged. (Previously the
    // orphan-close cleanup would silently delete them, leaving
    // garbage like `` `) without outputting content. ``.)
    XCTAssertEqual(
      stripReasoningBlocks("hello</think>world"),
      "hello</think>world"
    )
    XCTAssertEqual(
      stripReasoningBlocks("text mentioning <think>concept</think> here"),
      "text mentioning <think>concept</think> here"
    )
  }

  func testStripReasoningWithLiteralTagInsideBlock() {
    // The user's "`) without outputting content." regression: the
    // reasoning block contained a backtick-quoted `<think>...</think>`
    // mention. With the previous non-greedy regex we lost the answer.
    // Greedy LAST keeps the outer block fully bracketed.
    let input =
      "<think>The user describes (`<think>...</think>`) without outputting content."
      + " Reasoning continues here.</think>The summary text."
    XCTAssertEqual(stripReasoningBlocks(input), "The summary text.")
  }

  // End-to-end: decoder strips reasoning before returning content.
  func testDecoderStripsReasoningBlocks() throws {
    let json = #"""
      {
        "choices": [
          { "message": { "content": "<think>let me think...</think>The summary." } }
        ]
      }
      """#
    let result = try decodeRemoteOpenAIResponse(Data(json.utf8))
    XCTAssertEqual(result, "The summary.")
  }

  func testDecoderRejectsPureThinkAsEmpty() {
    let json = Data(#"{"choices":[{"message":{"content":"<think>only</think>"}}]}"#.utf8)
    XCTAssertThrowsError(try decodeRemoteOpenAIResponse(json)) { error in
      XCTAssertEqual(error as? RemoteOpenAIDecodeError, .contentEmpty)
    }
  }

  // MARK: - remoteAIResponseLanguageName

  func testLanguageNameZhHans() {
    XCTAssertEqual(remoteAIResponseLanguageName(for: "zh-Hans"), "Simplified Chinese")
  }

  func testLanguageNameZhHant() {
    XCTAssertEqual(remoteAIResponseLanguageName(for: "zh-Hant"), "Traditional Chinese")
  }

  func testLanguageNameFallbackViaLocale() {
    // Tags outside our shipped 7-language table fall back to Apple's
    // English-locale lookup so the prompt directive still says
    // something sensible. Asserts only the well-known mapping for
    // codes Apple is guaranteed to know.
    XCTAssertEqual(remoteAIResponseLanguageName(for: "fr"), "French")
    XCTAssertEqual(remoteAIResponseLanguageName(for: "ru"), "Russian")
    XCTAssertEqual(remoteAIResponseLanguageName(for: "it"), "Italian")
  }

  func testLanguageNameRejectsBogusCode() {
    // Apple echoes the code back when it has no name; we reject that
    // so garbage doesn't leak into the system prompt directive.
    // (Empty / nil tags fall back to system locale by design — that
    // path is covered by `testLanguageNameSystemAndNilCallable`.)
    XCTAssertNil(remoteAIResponseLanguageName(for: "xx-bogus"))
    XCTAssertNil(remoteAIResponseLanguageName(for: "qqq"))
  }

  func testLanguageNameEnglish() {
    XCTAssertEqual(remoteAIResponseLanguageName(for: "en"), "English")
  }

  func testLanguageNameSystemAndNilCallable() {
    // Result depends on the host locale — assert only that the type is
    // Optional<String> and the call doesn't crash. Don't assert value.
    let _: String? = remoteAIResponseLanguageName(for: "system")
    let _: String? = remoteAIResponseLanguageName(for: nil)
  }

  func testLanguageNameNormalisesRegion() {
    // "zh-Hans-CN" should normalise to "zh-Hans" and resolve.
    XCTAssertEqual(
      remoteAIResponseLanguageName(for: "zh-Hans-CN"),
      "Simplified Chinese"
    )
  }

  // MARK: - buildRemoteOpenAITextMessages with language

  func testTextMessagesWithLanguage() throws {
    // Language directive must be FRONT-LOADED in system AND mirrored
    // in the user message in the *target* language. Small models follow
    // the user message's language strongly; an English "Summarise the
    // following" prompt wins over an English-tagged system directive
    // even when both are present.
    let messages = buildRemoteOpenAITextMessages(
      "hi", responseLanguage: "Japanese")
    if case .text(let systemText) = messages[0].content {
      XCTAssertTrue(
        systemText.hasPrefix("Reply in Japanese."),
        "expected system text to start with the language directive; got: \(systemText)"
      )
      XCTAssertTrue(systemText.contains("All output must be in Japanese"))
    } else {
      XCTFail("expected text content")
    }
    if case .text(let userText) = messages[1].content {
      // User message wrapper must be in the target language and must
      // also reinforce the language directive ("regardless of input
      // language") so the model doesn't flip to English on ASCII bodies.
      XCTAssertTrue(
        userText.hasPrefix("以下の内容を日本語で要約してください"),
        "expected Japanese user wrapper; got: \(userText)"
      )
      XCTAssertTrue(
        userText.contains("入力が何語であっても"),
        "expected reinforcement clause; got: \(userText)"
      )
    } else {
      XCTFail("expected text content")
    }
  }

  func testTextMessagesUsesNativeWrappersForChinese() throws {
    let zhHans = buildRemoteOpenAITextMessages(
      "hi", responseLanguage: "Simplified Chinese")
    if case .text(let userText) = zhHans[1].content {
      XCTAssertTrue(userText.hasPrefix("请用简体中文总结以下内容"))
      XCTAssertTrue(userText.contains("无论输入是何种语言"))
    } else {
      XCTFail("expected text content")
    }
    let zhHant = buildRemoteOpenAITextMessages(
      "hi", responseLanguage: "Traditional Chinese")
    if case .text(let userText) = zhHant[1].content {
      XCTAssertTrue(userText.hasPrefix("請用繁體中文總結以下內容"))
      XCTAssertTrue(userText.contains("無論輸入是何種語言"))
    } else {
      XCTFail("expected text content")
    }
  }

  func testTextMessagesNoLanguage() throws {
    let messages = buildRemoteOpenAITextMessages("hi")
    if case .text(let systemText) = messages[0].content {
      XCTAssertFalse(systemText.hasPrefix("Reply in"))
      XCTAssertFalse(systemText.contains("All output must be in"))
    } else {
      XCTFail("expected text content")
    }
    if case .text(let userText) = messages[1].content {
      // No language → English fallback wrapper.
      XCTAssertTrue(userText.hasPrefix("Summarise the following:"))
    } else {
      XCTFail("expected text content")
    }
  }

  // MARK: - max_tokens encoding

  func testRequestOmitsMaxTokensWhenNil() throws {
    // Background summarisation passes no max_tokens — the model should
    // self-terminate at EOS rather than be capped by a fragile client-side
    // budget that reasoning models routinely exhaust inside <think>.
    let req = RemoteOpenAIRequest(
      model: "gpt-4o-mini",
      messages: [RemoteOpenAIMessage(role: "user", content: .text("hi"))],
      temperature: 0.2
    )
    let data = try JSONEncoder().encode(req)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssertFalse(
      json.contains("max_tokens"),
      "expected max_tokens key absent when nil; JSON: \(json)"
    )
  }

  func testRequestIncludesMaxTokensWhenSet() throws {
    // Test-connection probe sets a tiny cap (e.g. 4) to keep the health
    // check cheap. Confirm the field round-trips through encoding when
    // explicitly provided.
    let req = RemoteOpenAIRequest(
      model: "gpt-4o-mini",
      messages: [RemoteOpenAIMessage(role: "user", content: .text("hi"))],
      maxTokens: 4,
      temperature: 0
    )
    let data = try JSONEncoder().encode(req)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssertTrue(json.contains(#""max_tokens":4"#))
  }

  func testRequestEncodesPartsContentAsArray() throws {
    let req = RemoteOpenAIRequest(
      model: "gpt-4o-mini",
      messages: [
        RemoteOpenAIMessage(
          role: "user",
          content: .parts([.text("see"), .imageURL("data:image/png;base64,AAAA")])
        )
      ]
    )
    let data = try JSONEncoder().encode(req)
    let json = String(data: data, encoding: .utf8) ?? ""
    XCTAssertTrue(json.contains(#""type":"text""#))
    XCTAssertTrue(json.contains(#""type":"image_url""#))
    let escapedSlash = json.contains(#""url":"data:image\/png;base64,AAAA""#)
    let bareSlash = json.contains(#""url":"data:image/png;base64,AAAA""#)
    XCTAssertTrue(escapedSlash || bareSlash)
  }
}
