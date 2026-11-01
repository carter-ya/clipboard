import Foundation
import XCTest

@testable import ClipboardCore
@testable import DesktopServices

#if canImport(FoundationNetworking)
  import FoundationNetworking
#endif

private final class ModelFixtureStarts: @unchecked Sendable {
  private let lock = NSLock()
  private var callbacks: [String: @Sendable () -> Void] = [:]
  func observe(_ name: String, callback: @escaping @Sendable () -> Void) {
    lock.lock()
    callbacks[name] = callback
    lock.unlock()
  }
  func started(_ name: String) {
    lock.lock()
    let callback = callbacks.removeValue(forKey: name)
    lock.unlock()
    callback?()
  }
}
private final class ModelFixtureProtocol: URLProtocol, @unchecked Sendable {
  static let starts = ModelFixtureStarts()
  override class func canInit(with request: URLRequest) -> Bool { true }
  override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
  override func startLoading() {
    XCTAssertEqual(request.httpMethod, "GET")
    XCTAssertNil(request.httpBody)
    XCTAssertNil(request.value(forHTTPHeaderField: "Authorization"))
    XCTAssertNil(request.value(forHTTPHeaderField: "Cookie"))
    XCTAssertEqual(request.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
    let name = request.url!.lastPathComponent
    Self.starts.started(name)
    let headers =
      name == "wrong-length"
      ? ["Content-Length": "4"] : name == "gzip" ? ["Content-Encoding": "gzip"] : [:]
    let response = HTTPURLResponse(
      url: request.url!, statusCode: name == "forbidden" ? 403 : 200,
      httpVersion: "HTTP/1.1", headerFields: headers)!
    client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
    let bytes = Data((name == "oversize" ? "abcd" : name == "short" ? "ab" : "abc").utf8)
    client?.urlProtocol(self, didLoad: bytes)
    if !name.hasPrefix("held-") { client?.urlProtocolDidFinishLoading(self) }
  }
  override func stopLoading() {}
}

final class ModelDownloaderTests: XCTestCase {
  private func asset(_ scenario: String, host: String = "https://huggingface.co")
    -> DesktopModelAsset
  {
    .init(
      kind: .generative, id: "fixture", filename: "fixture.gguf",
      url: URL(string: host + "/synthetic/" + scenario)!,
      sha256: String(repeating: "a", count: 64), size: 3, license: "Apache-2.0",
      licenseURL: URL(string: "https://example.com/license")!,
      cardURL: URL(string: "https://example.com/card")!, licenseAcceptanceRequired: false)
  }
  private func destination() throws -> URL {
    let file = FileManager.default.temporaryDirectory.appendingPathComponent(
      "model-transfer-" + UUID().uuidString)
    try Data().write(to: file, options: .withoutOverwriting)
    addTeardownBlock { try? FileManager.default.removeItem(at: file) }
    return file
  }
  private func downloader() -> BoundedDesktopModelDownloader {
    let configuration = URLSessionConfiguration.ephemeral
    configuration.protocolClasses = [ModelFixtureProtocol.self]
    // Even an injected test configuration cannot add authentication headers.
    configuration.httpAdditionalHeaders = ["Authorization": "synthetic", "Cookie": "synthetic"]
    return .init(configuration: configuration)
  }
  func testAnonymousExactSizeStreamCompletesWithClosedDestination() async throws {
    let file = try destination()
    let reported = expectation(description: "progress")
    try await downloader().download(asset("valid"), to: file) { count in
      XCTAssertEqual(count, 3)
      reported.fulfill()
    }
    await fulfillment(of: [reported], timeout: 2)
    XCTAssertEqual(try Data(contentsOf: file), Data("abc".utf8))
    try FileManager.default.removeItem(at: file)
  }
  func testResponseStatusEncodingAndSizeAreEnforcedBeforeCommit() async throws {
    for (name, code, maximum) in [
      ("forbidden", DesktopModelAssetError.invalidResponse, 0), ("gzip", .invalidResponse, 0),
      ("wrong-length", .wrongSize, 0), ("oversize", .wrongSize, 0), ("short", .wrongSize, 2),
    ] {
      let file = try destination()
      do {
        try await downloader().download(asset(name), to: file) { _ in }
        XCTFail("Invalid transfer succeeded")
      } catch { XCTAssertEqual(error as? DesktopModelAssetError, code, name) }
      XCTAssertLessThanOrEqual(try Data(contentsOf: file).count, maximum, name)
    }
  }
  func testCancellationDrainsAndReleasesTheDestination() async throws {
    let file = try destination()
    let receiving = expectation(description: "request started")
    let name = "held-" + UUID().uuidString
    ModelFixtureProtocol.starts.observe(name) { receiving.fulfill() }
    let task = Task {
      try await downloader().download(asset(name), to: file) { _ in }
    }
    await fulfillment(of: [receiving], timeout: 2)
    task.cancel()
    do {
      try await task.value
      XCTFail("Cancelled download succeeded")
    } catch { XCTAssertTrue(error is CancellationError) }
    try FileManager.default.removeItem(at: file)
  }
  func testUnsupportedInitialEndpointsAndNonemptyDestinationsAreRefused() async throws {
    let file = try destination()
    for host in [
      "http://huggingface.co", "https://example.com", "https://user:password@huggingface.co",
      "https://huggingface.co.evil.invalid", "https://cdn.hf.co",
    ] {
      do {
        try await downloader().download(asset("valid", host: host), to: file) { _ in }
        XCTFail("Invalid endpoint")
      } catch { XCTAssertEqual(error as? DesktopModelAssetError, .invalidLocation) }
    }
    try Data("keep".utf8).write(to: file)
    do {
      try await downloader().download(asset("valid"), to: file) { _ in }
      XCTFail("Existing file was overwritten")
    } catch { XCTAssertEqual(error as? DesktopModelAssetError, .invalidLocation) }
    XCTAssertEqual(try Data(contentsOf: file), Data("keep".utf8))
  }
  func testRedirectsKeepOnlyAllowedHTTPSHostsAndRebuildAnonymousRequests() throws {
    let operation = ModelDownloadOperation(asset: asset("valid"), destination: try destination()) {
      _ in
    }
    let session = URLSession(configuration: .ephemeral)
    defer { session.invalidateAndCancel() }
    let task = session.dataTask(with: asset("valid").url)
    let response = HTTPURLResponse(
      url: asset("valid").url, statusCode: 302, httpVersion: nil, headerFields: nil)!
    for host in [
      "http://cdn.hf.co", "https://evil.invalid", "https://cdn.hf.co.evil.invalid",
      "https://user:pass@cdn.hf.co", "https://cdn.hf.co:444",
    ] {
      let rejected = ModelDownloadOperation(asset: asset("valid"), destination: try destination()) {
        _ in
      }
      rejected.urlSession(
        session, task: task, willPerformHTTPRedirection: response,
        newRequest: URLRequest(url: URL(string: host)!), completionHandler: { XCTAssertNil($0) })
    }
    for index in 0..<9 {
      var request = URLRequest(
        url: URL(string: "https://cas-bridge.xethub.hf.co/model?synthetic=1")!)
      request.setValue("synthetic", forHTTPHeaderField: "Authorization")
      request.setValue("synthetic", forHTTPHeaderField: "Cookie")
      request.httpMethod = "POST"
      request.httpBody = Data("synthetic".utf8)
      operation.urlSession(
        session, task: task, willPerformHTTPRedirection: response, newRequest: request
      ) { redirected in
        if index == 8 {
          XCTAssertNil(redirected)
          return
        }
        XCTAssertEqual(redirected?.httpMethod, "GET")
        XCTAssertNil(redirected?.httpBody)
        XCTAssertNil(redirected?.value(forHTTPHeaderField: "Authorization"))
        XCTAssertNil(redirected?.value(forHTTPHeaderField: "Cookie"))
        XCTAssertEqual(redirected?.value(forHTTPHeaderField: "Accept-Encoding"), "identity")
      }
    }
  }
}
