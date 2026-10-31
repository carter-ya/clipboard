import XCTest

@testable import ClipboardCore

final class DesktopAIConnectionTests: XCTestCase {
  private func settings() -> DesktopAISettings {
    var value = DesktopAISettings()
    value.enabled = true
    value.endpoint = "http://127.0.0.1:12345/v1"
    value.model = "fixture-model"
    return value
  }
  func testExplicitProbeUsesOnlyAFixedTinyMessageAndOptionalStoredCredential() async throws {
    let credentials = InMemoryDesktopCredentials()
    var configuration = settings()
    await credentials.save("synthetic-token", account: configuration.credentialAccount)
    let transport = FakeDesktopAITransport()
    let probe = DesktopAIConnectionProbe(credentials: credentials, transport: transport)
    let result = await probe.test(settings: configuration)
    XCTAssertEqual(result, .connected)
    configuration.usesCredential = true
    let authenticated = await probe.test(settings: configuration)
    XCTAssertEqual(authenticated, .connected)
    let requests = await transport.requests
    XCTAssertEqual(requests.count, 2)
    XCTAssertNil(requests[0].value(forHTTPHeaderField: "Authorization"))
    XCTAssertEqual(requests[1].value(forHTTPHeaderField: "Authorization"), "Bearer synthetic-token")
    for request in requests {
      XCTAssertEqual(request.url?.absoluteString, "http://127.0.0.1:12345/v1/chat/completions")
      XCTAssertEqual(request.httpMethod, "POST")
      XCTAssertEqual(request.timeoutInterval, 5)
      let data = try XCTUnwrap(request.httpBody)
      let body = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
      XCTAssertEqual(body["model"] as? String, "fixture-model")
      XCTAssertEqual(body["max_tokens"] as? Int, 4)
      XCTAssertEqual(body["temperature"] as? Int, 0)
      let expected = try JSONEncoder().encode(
        RemoteOpenAIRequest(
          model: "fixture-model", messages: buildRemoteOpenAITextMessages("reply OK"), maxTokens: 4,
          temperature: 0))
      XCTAssertEqual(
        try JSONSerialization.jsonObject(with: data) as? NSDictionary,
        try JSONSerialization.jsonObject(with: expected) as? NSDictionary)
      XCTAssertFalse(String(decoding: data, as: UTF8.self).contains("synthetic-token"))
    }
  }
  func testDisabledInvalidAndMissingCredentialNeverSend() async {
    let transport = FakeDesktopAITransport()
    let probe = DesktopAIConnectionProbe(
      credentials: InMemoryDesktopCredentials(), transport: transport)
    var configuration = settings()
    configuration.enabled = false
    let disabled = await probe.test(settings: configuration)
    XCTAssertEqual(disabled, .disabled)
    configuration = settings()
    configuration.endpoint = "http://example.com/v1"
    let invalid = await probe.test(settings: configuration)
    XCTAssertEqual(invalid, .invalidConfiguration)
    configuration = settings()
    configuration.usesCredential = true
    let missing = await probe.test(settings: configuration)
    XCTAssertEqual(missing, .credentialsUnavailable)
    let requests = await transport.requests
    XCTAssertTrue(requests.isEmpty)
  }
  func testHTTPFailuresAndUnusableSuccessHaveContentFreeOutcomes() async {
    let expected: [(Int, DesktopAIConnectionResult)] = [
      (301, .redirected), (401, .authenticationFailed), (403, .authenticationFailed),
      (404, .notFound), (429, .rateLimited), (400, .requestRejected), (503, .serverError),
      (200, .unusableResponse), (204, .unusableResponse),
    ]
    for (status, result) in expected {
      let probe = DesktopAIConnectionProbe(
        credentials: InMemoryDesktopCredentials(),
        transport: FakeDesktopAITransport(
          response: .init(data: Data("not a completion".utf8), status: status)))
      let observed = await probe.test(settings: settings())
      XCTAssertEqual(observed, result)
    }
    let oversized = DesktopAIConnectionProbe(
      credentials: InMemoryDesktopCredentials(),
      transport: FakeDesktopAITransport(
        response: .init(data: Data(repeating: 0, count: 64 * 1024 + 1), status: 200)))
    let observed = await oversized.test(settings: settings())
    XCTAssertEqual(observed, .unusableResponse)
  }

  private actor Gate {
    private var pending: [CheckedContinuation<DesktopAIConnectionResult, Never>] = []
    private var waiter: CheckedContinuation<Void, Never>?
    func run() async -> DesktopAIConnectionResult {
      await withCheckedContinuation {
        pending.append($0)
        waiter?.resume()
        waiter = nil
      }
    }
    func started() async { if pending.isEmpty { await withCheckedContinuation { waiter = $0 } } }
    func finish(_ result: DesktopAIConnectionResult) {
      pending.removeFirst().resume(returning: result)
    }
  }
  @MainActor func testDuplicateCancelAndRetryRejectLateNoncooperativeSuccess() async throws {
    let gate = Gate()
    let state = DesktopAIConnectionState(run: { _ in await gate.run() }, changed: { _, _ in })
    let first = try XCTUnwrap(state.start(settings: settings()))
    await gate.started()
    XCTAssertTrue(state.busy)
    XCTAssertNil(state.start(settings: settings()))
    state.cancel()
    XCTAssertFalse(state.busy)
    XCTAssertEqual(state.result, .cancelled)
    await gate.finish(.connected)
    await first.value
    XCTAssertEqual(state.result, .cancelled)
    let retry = try XCTUnwrap(state.start(settings: settings()))
    await gate.started()
    await gate.finish(.connected)
    await retry.value
    XCTAssertEqual(state.result, .connected)
    XCTAssertFalse(state.busy)
  }
  @MainActor func testDraftInvalidationAndShutdownIgnoreLateResults() async throws {
    let gate = Gate()
    let state = DesktopAIConnectionState(run: { _ in await gate.run() }, changed: { _, _ in })
    let first = try XCTUnwrap(state.start(settings: settings()))
    await gate.started()
    state.invalidate()
    await gate.finish(.authenticationFailed)
    await first.value
    XCTAssertNil(state.result)
    let second = try XCTUnwrap(state.start(settings: settings()))
    await gate.started()
    state.stop()
    await gate.finish(.connected)
    await second.value
    XCTAssertNil(state.result)
    XCTAssertFalse(state.busy)
    XCTAssertNil(state.start(settings: settings()))
  }
}
