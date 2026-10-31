import XCTest

@testable import ClipboardCore

final class SensitivityFilterTests: XCTestCase {
  private let context = ClipContext(sourceBundleID: nil, changeCount: 1, timestamp: Date())

  func testMarksSensitiveOnConcealedType() {
    let filter = SensitivityFilter(skipSensitive: true)
    let item = RawClipItem(
      payloads: [
        RawPayload(pasteboardType: "public.utf8-plain-text", data: Data("pw".utf8)),
        RawPayload(
          pasteboardType: SensitivityFilter.concealedType, data: Data()),
      ]
    )
    XCTAssertEqual(filter.evaluate(item, context: context), .markSensitive("concealedType"))
  }

  func testAcceptsWhenSkipDisabled() {
    let filter = SensitivityFilter(skipSensitive: false)
    let item = RawClipItem(
      payloads: [RawPayload(pasteboardType: SensitivityFilter.concealedType, data: Data())]
    )
    XCTAssertEqual(filter.evaluate(item, context: context), .accept)
  }

  func testAcceptsWhenNoConcealedTypeDeclared() {
    let filter = SensitivityFilter(skipSensitive: true)
    let item = RawClipItem(
      payloads: [RawPayload(pasteboardType: "public.utf8-plain-text", data: Data())]
    )
    XCTAssertEqual(filter.evaluate(item, context: context), .accept)
  }
}

final class BlocklistFilterTests: XCTestCase {
  private let item = RawClipItem()

  func testMarksSensitiveWhenBundleInList() {
    let filter = BlocklistFilter(blockedBundleIDs: ["com.1password.1password"])
    let ctx = ClipContext(
      sourceBundleID: "com.1password.1password", changeCount: 1, timestamp: Date())
    XCTAssertEqual(
      filter.evaluate(item, context: ctx),
      .markSensitive("blockedSource:com.1password.1password")
    )
  }

  func testAcceptsWhenBundleNotInList() {
    let filter = BlocklistFilter(blockedBundleIDs: ["com.other.app"])
    let ctx = ClipContext(
      sourceBundleID: "com.apple.TextEdit", changeCount: 1, timestamp: Date())
    XCTAssertEqual(filter.evaluate(item, context: ctx), .accept)
  }

  func testAcceptsWhenBundleIsNil() {
    let filter = BlocklistFilter(blockedBundleIDs: ["com.1password.1password"])
    let ctx = ClipContext(sourceBundleID: nil, changeCount: 1, timestamp: Date())
    XCTAssertEqual(filter.evaluate(item, context: ctx), .accept)
  }

  func testWindowsExecutableIdentityMatchesRegardlessOfCase() {
    let filter = BlocklistFilter(blockedBundleIDs: ["windows:bitwarden.exe"])
    for source in ["windows:Bitwarden.exe", "windows:BiTwArDeN.EXE", "WINDOWS:BITWARDEN.EXE"] {
      let context = ClipContext(sourceBundleID: source, changeCount: 1, timestamp: Date())
      XCTAssertEqual(
        filter.evaluate(item, context: context), .markSensitive("blockedSource:" + source))
    }
  }

  func testWindowsSetConfigurationRetainsOriginalSpelling() {
    let configured: Set<String> = ["WINDOWS:BiTwArDeN.EXE"]
    let filter = BlocklistFilter(blockedBundleIDs: configured)
    XCTAssertEqual(filter.blockedBundleIDs, configured)
    let source = "windows:bitwarden.exe"
    let context = ClipContext(sourceBundleID: source, changeCount: 1, timestamp: Date())
    XCTAssertEqual(
      filter.evaluate(item, context: context), .markSensitive("blockedSource:" + source))
  }

  func testExecutableMatchingRemainsExactAndNamespaceSpecific() {
    let filter = BlocklistFilter(blockedBundleIDs: ["windows:bitwarden.exe"])
    for source in ["windows:BitwardenHelper.exe", "linux:bitwarden.exe", "com.bitwarden.desktop"] {
      let context = ClipContext(sourceBundleID: source, changeCount: 1, timestamp: Date())
      XCTAssertEqual(filter.evaluate(item, context: context), .accept)
    }
  }

  func testMacBundleAndLinuxWindowClassMatchingKeepsItsExistingCaseSemantics() {
    let filter = BlocklistFilter(blockedBundleIDs: ["com.example.Password", "linux:Bitwarden"])
    for source in ["com.example.password", "linux:bitwarden"] {
      let context = ClipContext(sourceBundleID: source, changeCount: 1, timestamp: Date())
      XCTAssertEqual(filter.evaluate(item, context: context), .accept)
    }
  }

  func testCaseVariantWindowsCaptureNeverPersistsItsPayload() async throws {
    let clipboard = FakeRichClipboard()
    let monitor = RichClipboardMonitor(
      clipboard: clipboard,
      filter: BlocklistFilter(blockedBundleIDs: ["WINDOWS:BiTwArDeN.EXE"]))
    let data = Data("synthetic source fixture".utf8)
    clipboard.push(
      .init(
        payloads: [.init(pasteboardType: "public.utf8-plain-text", data: data)],
        sourceAppID: "windows:bitwarden.exe", sensitive: false, revision: 1))
    monitor.pulse()
    var changes = monitor.changes.makeAsyncIterator()
    let next = await changes.next()
    let captured = try XCTUnwrap(next)
    XCTAssertTrue(captured.isSensitive)
    XCTAssertEqual(captured.bundleID, "windows:bitwarden.exe")
    let root = FileManager.default.temporaryDirectory.appendingPathComponent(
      "source-case-" + UUID().uuidString)
    defer { try? FileManager.default.removeItem(at: root) }
    let store = try await JSONSnapshotClipStore(root: root, inlineThresholdBytes: 1)
    await store.insert(captured)
    await store.flush()
    let live = await store.all()
    XCTAssertEqual(live.count, 1)
    XCTAssertTrue(live.first?.sensitive == true)
    let disk =
      try JSONSerialization.jsonObject(
        with: Data(contentsOf: root.appendingPathComponent("history.json"))) as? [String: Any]
    XCTAssertEqual((disk?["items"] as? [Any])?.count, 0)
    XCTAssertTrue(
      try FileManager.default.contentsOfDirectory(atPath: root.appendingPathComponent("blobs").path)
        .isEmpty)
    monitor.stop()
  }

  func testDefaultsCoversMajorPasswordManagers() {
    XCTAssertTrue(BlocklistFilter.defaults.contains("com.1password.1password"))
    XCTAssertTrue(BlocklistFilter.defaults.contains("com.bitwarden.desktop"))
    XCTAssertTrue(BlocklistFilter.defaults.contains("com.apple.keychainaccess"))
  }
}
