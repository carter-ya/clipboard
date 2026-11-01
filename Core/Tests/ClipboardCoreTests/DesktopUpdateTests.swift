import XCTest

@testable import ClipboardCore

final class DesktopUpdateTests: XCTestCase {
  private func expect(
    _ actual: DesktopUpdateResult, _ expected: DesktopUpdateResult, file: StaticString = #filePath,
    line: UInt = #line
  ) { XCTAssertEqual(actual, expected, file: file, line: line) }
  func testSemanticVersionOrderingAndStrictParsing() throws {
    let ordered = [
      "0.1.0-preview.1", "0.1.0-preview.2", "0.1.0-preview.10", "0.1.0-rc.1", "0.1.0", "0.2.0",
      "1.0.0",
    ]
    let values = try ordered.map { try XCTUnwrap(DesktopReleaseVersion($0)) }
    for (a, b) in zip(values, values.dropFirst()) { XCTAssertLessThan(a, b) }
    XCTAssertEqual(DesktopReleaseVersion("1.0.0+build.1"), DesktopReleaseVersion("1.0.0+other"))
    for invalid in [
      "", "1.2", "01.2.3", "1.2.3-01", "1.2.3-", "1.2.3+", "1.2.3/evil", "1.2.3\n", "１.2.3",
      String(repeating: "9", count: 200),
    ] {
      XCTAssertNil(DesktopReleaseVersion(invalid), invalid)
    }
  }
  private func release(
    _ version: String, target: String = "linux-arm64", draft: Bool = false, prerelease: Bool = true,
    uploaded: Bool = true
  ) -> [String: Any] {
    let package =
      "ClipboardDesktop-\(version)-\(target)" + (target == "windows-x64" ? "-setup.exe" : ".tar.gz")
    return [
      "tag_name": "desktop-v" + version, "draft": draft, "prerelease": prerelease,
      "assets": [
        ["name": package, "state": uploaded ? "uploaded" : "new", "size": 100],
        ["name": "SHA256SUMS", "state": "uploaded", "size": 80],
      ],
    ]
  }
  private func checker(
    _ releases: [[String: Any]], current: String = "0.1.0-preview.1",
    target: DesktopUpdateTarget = .linuxARM64, status: Int = 200
  ) throws -> (DesktopUpdateChecker, FakeDesktopAITransport) {
    let transport = FakeDesktopAITransport(
      response: .init(data: try JSONSerialization.data(withJSONObject: releases), status: status))
    return (
      DesktopUpdateChecker(currentVersion: current, target: target, transport: transport), transport
    )
  }
  func testSelectsHighestCompatibleUploadedPackageAndConstructsOfficialPage() async throws {
    let (probe, transport) = try checker([
      release("0.2.0-preview.1"), release("0.3.0", prerelease: false),
      release("9.0.0", target: "windows-x64"), release("8.0.0", draft: true),
      release("7.0.0", uploaded: false),
    ])
    let result = await probe.check()
    guard case .available(let update) = result else { return XCTFail("Expected compatible update") }
    XCTAssertEqual(update.version, "0.3.0")
    XCTAssertEqual(
      update.page.absoluteString,
      "https://github.com/carter-ya/clipboard/releases/tag/desktop-v0.3.0")
    let requests = await transport.requests
    let request = try XCTUnwrap(requests.first)
    XCTAssertEqual(
      request.url?.absoluteString,
      "https://api.github.com/repos/carter-ya/clipboard/releases?per_page=20")
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertNil(request.httpBody)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(request.timeoutInterval, 10)
  }
  func testStableChannelIgnoresPreviewsAndRequiresMatchingPackageAndChecksum() async throws {
    var noChecksum = release("3.0.0", prerelease: false)
    noChecksum["assets"] = [
      ["name": "ClipboardDesktop-3.0.0-linux-arm64.tar.gz", "state": "uploaded", "size": 100]
    ]
    let (probe, _) = try checker(
      [release("2.0.0-preview.1"), release("1.0.0", prerelease: false), noChecksum],
      current: "1.0.0")
    expect(await probe.check(), .upToDate)
    let (windows, _) = try checker(
      [release("2.0.0", target: "linux-arm64", prerelease: false)], target: .windowsX64)
    expect(await windows.check(), .noCompatibleRelease)
    let (none, _) = try checker([])
    expect(await none.check(), .noCompatibleRelease)
  }
  func testRejectsUntrustedTagsMalformedOversizedAndHTTPFailures() async throws {
    var unsafe = release("0.2.0")
    unsafe["tag_name"] = "https://evil.invalid/0.2.0"
    let (probe, _) = try checker([unsafe])
    expect(await probe.check(), .noCompatibleRelease)
    for (status, expected) in [
      (403, DesktopUpdateResult.rateLimited), (429, .rateLimited), (302, .failed), (500, .failed),
    ] {
      let (probe, _) = try checker([], status: status)
      expect(await probe.check(), expected)
    }
    let transport = FakeDesktopAITransport(
      response: .init(data: Data(repeating: 32, count: 1024 * 1024 + 1), status: 200))
    expect(
      await DesktopUpdateChecker(currentVersion: "0.1.0", target: .linuxARM64, transport: transport)
        .check(), .failed)
    expect(
      await DesktopUpdateChecker(
        currentVersion: "invalid", target: .linuxARM64, transport: transport
      ).check(), .invalidVersion)
  }
  func testAllNativeTargetsRequireTheirOwnInstallableAsset() async throws {
    for target in [DesktopUpdateTarget.windowsX64, .linuxX64, .linuxARM64] {
      let (probe, _) = try checker(
        [release("0.2.0", target: target.rawValue, prerelease: false)], target: target)
      guard case .available(let update) = await probe.check() else {
        XCTFail("Missing native package for " + target.rawValue)
        continue
      }
      XCTAssertEqual(update.version, "0.2.0")
    }
    let transport = FakeDesktopAITransport(
      response: .init(data: Data("not release JSON".utf8), status: 200))
    expect(
      await DesktopUpdateChecker(currentVersion: "0.1.0", target: .linuxARM64, transport: transport)
        .check(), .failed)
  }

  private actor SuspendedChecker: DesktopUpdateChecking {
    var waiter: CheckedContinuation<DesktopUpdateResult, Never>?
    var count = 0
    let started: @Sendable () -> Void
    init(started: @escaping @Sendable () -> Void) { self.started = started }
    func check() async -> DesktopUpdateResult {
      count += 1
      started()
      return await withCheckedContinuation { waiter = $0 }
    }
    func release() {
      waiter?.resume(returning: .upToDate)
      waiter = nil
    }
  }
  @MainActor func testCancelRejectsLateCompletionDuplicateStartAndStoppedWork() async {
    let started = expectation(description: "update check began")
    let checker = SuspendedChecker { started.fulfill() }
    var observed: DesktopUpdateResult?
    let state = DesktopUpdateState(checker: checker) { _, result in observed = result }
    state.start()
    state.start()
    await fulfillment(of: [started], timeout: 3)
    XCTAssertTrue(state.busy)
    let count = await checker.count
    XCTAssertEqual(count, 1)
    state.cancel()
    await checker.release()
    for _ in 0..<20 { await Task.yield() }
    XCTAssertFalse(state.busy)
    XCTAssertNil(observed)
    state.stop()
    state.start()
    XCTAssertFalse(state.busy)
    XCTAssertNil(observed)
  }

}
