import XCTest

@testable import ClipboardCore

final class SecretPatternSensitivityTests: XCTestCase {
  private let context = ClipContext(sourceBundleID: nil, changeCount: 1, timestamp: Date())
  private var key: String { "sk-" + String(repeating: "Synthetic123", count: 4) }
  private func decision(_ text: String, type: String = "public.utf8-plain-text") -> FilterDecision {
    SensitivityFilter().evaluate(
      RawClipItem(payloads: [.init(pasteboardType: type, data: Data(text.utf8))]), context: context)
  }

  func testPrefixedCredentialsUseTheExistingSensitiveDecision() {
    let suffix = String(repeating: "Synthetic123", count: 4)
    for prefix in [
      "sk-", "sk-proj-", "sk-ant-api03-", "ghp_", "github_pat_", "sk_live_", "rk_test_", "sk_org_",
    ] {
      XCTAssertEqual(
        decision(prefix + suffix), .markSensitive("credentialPattern"), "prefix \(prefix)")
    }
  }

  func testRecognizesKeysInsideCompleteMultilineTextBeyondThePreview() {
    let text = String(repeating: "ordinary text\n", count: 10000) + "API_KEY=\"" + key + "\"\n"
    XCTAssertEqual(decision(text), .markSensitive("credentialPattern"))
  }

  func testAdditionalDefinedTokenAndPrivateKeyRules() {
    let suffix = String(repeating: "Synthetic123", count: 4)
    for text in [
      "glpat-" + suffix, "xoxb-" + suffix, "xapp-" + suffix, "xwfp-" + suffix, "whsec_" + suffix,
      "npm_" + String(repeating: "A1b2", count: 9), "AKIA" + String(repeating: "AB12", count: 4),
      "ASIA" + String(repeating: "CD34", count: 4), "-----BEGIN OPENSSH PRIVATE KEY-----\nfixture",
    ] {
      XCTAssertEqual(decision(text), .markSensitive("credentialPattern"))
    }
    XCTAssertEqual(decision("-----BEGIN PUBLIC KEY-----\nfixture"), .accept)
  }

  func testUTF16KeysUseTheSameSensitivePolicy() {
    for type in ["public.utf16-plain-text", "public.utf16-external-plain-text"] {
      for encoding in [String.Encoding.utf16, .utf16LittleEndian, .utf16BigEndian] {
        let bytes = key.data(using: encoding)!
        let raw = RawClipItem(payloads: [.init(pasteboardType: type, data: bytes)])
        XCTAssertEqual(
          SensitivityFilter().evaluate(raw, context: context), .markSensitive("credentialPattern"))
      }
    }
  }

  func testVisibleRichTextEscapesDoNotBypassRecognition() {
    let suffix = String(repeating: "Synthetic123", count: 4)
    XCTAssertEqual(
      decision("<b>sk&#45;" + suffix + "</b>", type: "public.html"),
      .markSensitive("credentialPattern"))
    XCTAssertEqual(
      decision("{\\rtf1 sk\\u45?" + suffix + "}", type: "public.rtf"),
      .markSensitive("credentialPattern"))
  }

  func testRichClipboardCaptureUsesMemoryOnlyStorageAndExcludesExports() async throws {
    let clipboard = FakeRichClipboard()
    let monitor = RichClipboardMonitor(clipboard: clipboard, filter: SensitivityFilter())
    defer { monitor.stop() }
    let bytes = Data(key.utf8)
    clipboard.push(
      .init(payloads: [.init(pasteboardType: "public.utf8-plain-text", data: bytes)], revision: 1))
    monitor.pulse()
    var changes = monitor.changes.makeAsyncIterator()
    let next = await changes.next()
    let captured = try XCTUnwrap(next)
    XCTAssertTrue(captured.isSensitive)
    XCTAssertEqual(captured.sensitivityReason, "credentialPattern")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "secret-capture-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(root: root, inlineThresholdBytes: 1)
    await store.insert(captured)
    await store.flush()
    let items = await store.all()
    let item = try XCTUnwrap(items.first)
    XCTAssertTrue(item.sensitive)
    XCTAssertEqual(item.payloads.first?.inlineData, bytes)
    XCTAssertNil(item.payloads.first?.blobPath)
    let blobFiles = try await store.blobs.listFiles()
    XCTAssertTrue(blobFiles.isEmpty)
    let disk =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("history.json"))) as? [String: Any]
    XCTAssertEqual((disk?["items"] as? [Any])?.count, 0)
    let transport = FakeDesktopAITransport()
    let ocr = FakeDesktopOCR()
    let analysis = DesktopAnalysis(
      credentials: InMemoryDesktopCredentials(), transport: transport, ocr: ocr, blobRoot: nil)
    var settings = DesktopAISettings()
    settings.enabled = true
    settings.model = "synthetic-fixture"
    do {
      _ = try await analysis.summarize(item, settings: settings)
      XCTFail("recognized credential reached remote analysis")
    } catch { XCTAssertEqual(error as? DesktopServiceError, .sensitiveContent) }
    let requests = await transport.requests
    let ocrCalls = await ocr.calls
    XCTAssertTrue(requests.isEmpty)
    XCTAssertEqual(ocrCalls, 0)
    for suffix in ["json", "zip"] {
      let archive = root.appendingPathComponent("export." + suffix)
      try DesktopHistoryArchive.write(
        items: items, blobRoot: root.appendingPathComponent("blobs"), to: archive)
      XCTAssertTrue(try DesktopHistoryArchive.read(from: archive).isEmpty)
    }
  }

  func testDisabledMaskingRetainsThePasswordPreferenceSemantics() {
    let item = RawClipItem(payloads: [
      .init(pasteboardType: "public.utf8-plain-text", data: Data(key.utf8))
    ])
    XCTAssertEqual(
      SensitivityFilter(skipSensitive: false).evaluate(item, context: context), .accept)
  }

  func testOrdinaryWordsPlaceholdersAndPublishableKeysAreNotCredentials() {
    for text in [
      "sk-*", "sk-example", "sk-learn", "task-" + String(repeating: "a", count: 40),
      "pk_live_" + String(repeating: "Synthetic123", count: 4), "https://example.com/docs",
      "a normal note",
    ] {
      XCTAssertEqual(decision(text), .accept)
    }
  }

  func testBinaryImageAndFileReferenceAreNotInterpretedAsTextSecrets() {
    for type in ["public.png", "public.file-url", "application/octet-stream"] {
      XCTAssertEqual(decision(key, type: type), .accept)
    }
  }

  func testSensitiveRecaptureUpgradesAnExistingOrdinaryRecord() async throws {
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "secret-recapture-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(
      root: root, inlineThresholdBytes: 1, sensitiveTextMasking: false)
    let bytes = Data(key.utf8)
    var raw = RawClipItem(
      payloads: [.init(pasteboardType: "public.utf8-plain-text", data: bytes)],
      totalBytes: bytes.count)
    await store.insert(raw)
    let originalItems = await store.all()
    let original = try XCTUnwrap(originalItems.first)
    await store.pin(id: original.id)
    await store.flush()
    // This is the monitor's existing sensitive result, independently of the
    // new recognizer. Recapture must not bump an unmasked persisted duplicate.
    raw.isSensitive = true
    raw.sensitivityReason = "credentialPattern"
    await store.insert(raw)
    await store.updateSummary(
      id: original.id, summary: "late synthetic summary", source: .naturalLanguage)
    await store.flush()
    let updatedItems = await store.all()
    let updated = try XCTUnwrap(updatedItems.first)
    XCTAssertEqual(updatedItems.count, 1)
    XCTAssertEqual(updated.id, original.id)
    XCTAssertTrue(updated.pinned)
    XCTAssertTrue(updated.sensitive)
    XCTAssertNil(updated.summary)
    XCTAssertEqual(updated.sensitivityReason, "credentialPattern")
    XCTAssertEqual(updated.payloads.first?.inlineData, bytes)
    XCTAssertNil(updated.payloads.first?.blobPath)
    let disk =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("history.json"))) as? [String: Any]
    XCTAssertEqual((disk?["items"] as? [Any])?.count, 0)
    let files = try await store.blobs.listFiles()
    XCTAssertTrue(files.isEmpty)
  }
}
