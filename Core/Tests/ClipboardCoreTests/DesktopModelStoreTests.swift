import XCTest

@testable import ClipboardCore

final class DesktopModelStoreTests: XCTestCase {
  private actor Downloader: DesktopModelAssetDownloading {
    var bytes = Data("abc".utf8)
    var calls = 0
    var held = false
    var continuation: CheckedContinuation<Void, Never>?
    func configure(_ bytes: Data, held: Bool = false) {
      self.bytes = bytes
      self.held = held
    }
    func waitForStart() async throws {
      for _ in 0..<200 {
        if calls > 0 { return }
        try await Task.sleep(nanoseconds: 10_000_000)
      }
      throw DesktopModelAssetError.unavailable
    }
    func release() {
      continuation?.resume()
      continuation = nil
    }
    func download(
      _ asset: DesktopModelAsset, to destination: URL,
      progress: @escaping @Sendable (Int64) -> Void
    ) async throws {
      calls += 1
      if held { await withCheckedContinuation { continuation = $0 } }
      // Deliberately ignore cancellation to exercise the store's final gate.
      try bytes.write(to: destination)
      progress(Int64(bytes.count))
    }
  }
  private func asset(_ kind: DesktopModelKind = .generative) -> DesktopModelAsset {
    .init(
      kind: kind, id: "synthetic-v1", filename: "model.fixture",
      url: URL(string: "https://huggingface.co/synthetic/model/resolve/fixed/model")!,
      sha256: "ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad",
      size: 3, license: kind == .generative ? "Apache-2.0" : "AFL-3.0",
      licenseURL: URL(string: "https://example.com/license")!,
      cardURL: URL(string: "https://example.com/card")!,
      licenseAcceptanceRequired: kind == .entities)
  }
  private func temporary() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(
      "model 日本語 " + UUID().uuidString)
    try FileManager.default.createDirectory(at: url, withIntermediateDirectories: false)
    addTeardownBlock { try? FileManager.default.removeItem(at: url) }
    return url
  }
  private func store(_ root: URL, _ downloader: Downloader) throws -> DesktopModelStore {
    try .init(root: root, downloader: downloader, catalog: [asset(), asset(.entities)])
  }
  private func failure(_ code: DesktopModelAssetError, _ action: () async throws -> Void) async {
    do {
      try await action()
      XCTFail("Operation unexpectedly succeeded")
    } catch { XCTAssertEqual(error as? DesktopModelAssetError, code) }
  }

  func testPassiveConstructionAndRefreshDoNotCreateDirectoriesOrDownload() async throws {
    let root = try temporary().appendingPathComponent("models")
    let downloader = Downloader()
    let store = try store(root, downloader)
    try await store.refresh(.generative)
    let value = await store.state(.generative)
    let calls = await downloader.calls
    XCTAssertEqual(value, .init(status: .missing, installed: false))
    XCTAssertEqual(calls, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
  }
  func testLicenseRequiredBeforeAnyFilesystemOrNetworkWork() async throws {
    let root = try temporary().appendingPathComponent("models")
    let downloader = Downloader()
    let store = try store(root, downloader)
    await failure(.licenseNotAccepted) { try await store.install(.entities) }
    await failure(.licenseNotAccepted) { try await store.importFile(.entities, from: root) }
    let calls = await downloader.calls
    XCTAssertEqual(calls, 0)
    XCTAssertFalse(FileManager.default.fileExists(atPath: root.path))
    try await store.install(.entities, licenseAccepted: true)
    let relaunched = try self.store(root, downloader)
    try await relaunched.refresh(.entities)
    let value = await relaunched.state(.entities)
    XCTAssertEqual(value, .init(status: .ready, installed: true))
  }
  func testVerifiedInstallSurvivesRelaunchAndUsesNoSecondDownload() async throws {
    let root = try temporary().appendingPathComponent("models")
    let downloader = Downloader()
    let store = try store(root, downloader)
    try await store.install(.generative)
    let installed = await store.installedURL(.generative)
    let path = try XCTUnwrap(installed)
    XCTAssertEqual(try Data(contentsOf: path), Data("abc".utf8))
    XCTAssertEqual(path.lastPathComponent, asset().sha256 + ".gguf")
    let relaunched = try self.store(root, downloader)
    try await relaunched.refresh(.generative)
    let ready = await relaunched.state(.generative)
    let calls = await downloader.calls
    XCTAssertEqual(ready, .init(status: .ready, installed: true))
    XCTAssertEqual(calls, 1)
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
        .contains(where: { $0.hasPrefix(".pending-") || $0.hasPrefix(".backup-") }))
  }
  func testBadReplacementPreservesInstalledModelAndCleansStaging() async throws {
    let root = try temporary().appendingPathComponent("models")
    let downloader = Downloader()
    let store = try store(root, downloader)
    try await store.install(.generative)
    let installed = await store.installedURL(.generative)
    let path = try XCTUnwrap(installed)
    for (bytes, code) in [
      (Data("abd".utf8), DesktopModelAssetError.digestMismatch),
      (Data("ab".utf8), .wrongSize), (Data("abcd".utf8), .wrongSize),
    ] {
      await downloader.configure(bytes)
      await failure(code) { try await store.install(.generative) }
      let state = await store.state(.generative)
      XCTAssertEqual(state, .init(status: .failed(code), installed: true))
      XCTAssertEqual(try Data(contentsOf: path), Data("abc".utf8))
    }
    XCTAssertFalse(
      try FileManager.default.contentsOfDirectory(atPath: path.deletingLastPathComponent().path)
        .contains(where: { $0.hasPrefix(".pending-") }))
  }
  func testImportVerifiesCopiedBytesAndLeavesSourceUntouched() async throws {
    let parent = try temporary()
    let source = parent.appendingPathComponent("input 日本語.gguf")
    try Data("abc".utf8).write(to: source)
    let downloader = Downloader()
    let store = try store(parent.appendingPathComponent("models"), downloader)
    try await store.importFile(.generative, from: source)
    let installed = await store.installedURL(.generative)
    let path = try XCTUnwrap(installed)
    try Data("abd".utf8).write(to: source)
    XCTAssertEqual(try Data(contentsOf: path), Data("abc".utf8))
    let calls = await downloader.calls
    XCTAssertEqual(calls, 0)
  }
  func testRemovalLeavesUnrelatedFilesAndOtherModelKind() async throws {
    let root = try temporary().appendingPathComponent("models")
    let store = try store(root, Downloader())
    try await store.install(.generative)
    try await store.install(.entities, licenseAccepted: true)
    let directory = root.appendingPathComponent("generative")
    let unrelated = directory.appendingPathComponent("notes.txt")
    try Data("keep".utf8).write(to: unrelated)
    let installed = await store.installedURL(.entities)
    let entity = try XCTUnwrap(installed)
    try await store.remove(.generative)
    XCTAssertEqual(try Data(contentsOf: unrelated), Data("keep".utf8))
    XCTAssertEqual(try Data(contentsOf: entity), Data("abc".utf8))
    XCTAssertTrue(FileManager.default.fileExists(atPath: root.path))
    let state = await store.state(.generative)
    XCTAssertEqual(state, .init(status: .missing, installed: false))
  }
  func testNonemptyUnmarkedDirectoryIsNeverAdoptedOrRemoved() async throws {
    let root = try temporary()
    let file = root.appendingPathComponent("unrelated")
    try Data("keep".utf8).write(to: file)
    let downloader = Downloader()
    let store = try store(root, downloader)
    await failure(.invalidLocation) { try await store.install(.generative) }
    await failure(.invalidLocation) { try await store.remove(.generative) }
    let calls = await downloader.calls
    XCTAssertEqual(calls, 0)
    XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
  }
  func testModifiedModelIsNotAvailableAfterPassiveVerification() async throws {
    let root = try temporary().appendingPathComponent("models")
    let downloader = Downloader()
    let store = try store(root, downloader)
    try await store.install(.generative)
    let installed = await store.installedURL(.generative)
    let path = try XCTUnwrap(installed)
    try Data("abd".utf8).write(to: path)
    await failure(.digestMismatch) { try await store.refresh(.generative) }
    let state = await store.state(.generative)
    XCTAssertEqual(state, .init(status: .failed(.digestMismatch), installed: false))
    // Reinstall can replace a corrupt file only when its ownership is intact.
    try await store.install(.generative)
    XCTAssertEqual(try Data(contentsOf: path), Data("abc".utf8))
  }
  func testCancellationDrainsTransferAndPreventsLateCommitOrProgress() async throws {
    let root = try temporary().appendingPathComponent("models")
    let downloader = Downloader()
    await downloader.configure(Data("abc".utf8), held: true)
    let store = try store(root, downloader)
    let transfer = Task { try await store.install(.generative) }
    try await downloader.waitForStart()
    await failure(.busy) { try await store.remove(.generative) }
    let cancellation = Task { await store.cancel(.generative) }
    for _ in 0..<1000 {
      if await store.state(.generative).status == .cancelling { break }
      await Task.yield()
    }
    let cancelling = await store.state(.generative)
    XCTAssertEqual(cancelling.status, .cancelling)
    await failure(.busy) { try await store.install(.entities, licenseAccepted: true) }
    await downloader.release()
    await cancellation.value
    do {
      try await transfer.value
      XCTFail("Cancelled transfer committed")
    } catch { XCTAssertTrue(error is CancellationError) }
    for _ in 0..<10 { await Task.yield() }
    let state = await store.state(.generative)
    XCTAssertEqual(state, .init(status: .missing, installed: false))
    XCTAssertEqual(
      try FileManager.default.contentsOfDirectory(
        atPath: root.appendingPathComponent("generative").path), [])
  }
  func testShutdownPreventsFurtherWorkAndFinishesObservation() async throws {
    let store = try store(temporary().appendingPathComponent("models"), Downloader())
    var iterator = await store.changes().makeAsyncIterator()
    let initial = await iterator.next()
    XCTAssertEqual(initial?[.generative], .init(status: .missing, installed: false))
    await store.shutdown()
    let final = await iterator.next()
    XCTAssertNil(final)
    await failure(.unavailable) { try await store.install(.generative) }
  }
  func testCancellationAndPublicationHaveOneWinner() throws {
    let cancelled = DesktopModelCommitGate()
    XCTAssertTrue(cancelled.cancel())
    XCTAssertThrowsError(try cancelled.commit { XCTFail("Published after cancellation") })
    let committed = DesktopModelCommitGate()
    XCTAssertEqual(try committed.commit { 42 }, 42)
    XCTAssertFalse(committed.cancel())
    XCTAssertNoThrow(try committed.check())
  }
  func testUnownedDigestNamedFileIsNeverReplacedOrRemoved() async throws {
    let root = try temporary().appendingPathComponent("models")
    _ = try DesktopModelFiles.root(root, create: true)
    let directory = root.appendingPathComponent("generative")
    _ = try DesktopModelFiles.directory(directory, create: true)
    let file = directory.appendingPathComponent(asset().sha256 + ".gguf")
    try Data("keep".utf8).write(to: file)
    let store = try store(root, Downloader())
    await failure(.invalidLocation) { try await store.install(.generative) }
    try await store.remove(.generative)
    XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
  }
  func testInvalidOwnershipStopsRemovalBeforeAnyModelDeletion() async throws {
    let root = try temporary().appendingPathComponent("models")
    let store = try store(root, Downloader())
    try await store.install(.generative)
    let installed = await store.installedURL(.generative)
    let file = try XCTUnwrap(installed)
    let forged = file.deletingLastPathComponent().appendingPathComponent(".owned-unrelated.json")
    try Data("{}".utf8).write(to: forged)
    await failure(.invalidLocation) { try await store.remove(.generative) }
    XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
    XCTAssertEqual(try Data(contentsOf: forged), Data("{}".utf8))
  }
  #if !os(Windows)
    func testSymlinkRootModelAndImportAreRefusedWithoutFollowingTargets() async throws {
      let parent = try temporary()
      let outside = parent.appendingPathComponent("outside")
      try FileManager.default.createDirectory(at: outside, withIntermediateDirectories: false)
      let linkedRoot = parent.appendingPathComponent("linked-root")
      try FileManager.default.createSymbolicLink(at: linkedRoot, withDestinationURL: outside)
      let downloader = Downloader()
      let linked = try store(linkedRoot, downloader)
      await failure(.invalidLocation) { try await linked.install(.generative) }
      XCTAssertEqual(try FileManager.default.contentsOfDirectory(atPath: outside.path), [])
      let root = parent.appendingPathComponent("models")
      let store = try store(root, downloader)
      try await store.install(.generative)
      let installed = await store.installedURL(.generative)
      let file = try XCTUnwrap(installed)
      let target = outside.appendingPathComponent("model.gguf")
      try Data("abc".utf8).write(to: target)
      try FileManager.default.removeItem(at: file)
      try FileManager.default.createSymbolicLink(at: file, withDestinationURL: target)
      await failure(.invalidLocation) { try await store.refresh(.generative) }
      await failure(.invalidLocation) { try await store.remove(.generative) }
      await failure(.invalidLocation) { try await store.importFile(.generative, from: file) }
      XCTAssertEqual(try Data(contentsOf: target), Data("abc".utf8))
    }
  #endif
}
