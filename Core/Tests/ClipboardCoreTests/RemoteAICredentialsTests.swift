import XCTest

@testable import ClipboardCore

final class RemoteAICredentialsTests: XCTestCase {
  private var testBaseURL: String!

  override func setUpWithError() throws {
    try XCTSkipUnless(
      ProcessInfo.processInfo.environment["CLIPBOARD_KEYCHAIN_TEST"] == "1",
      "Set CLIPBOARD_KEYCHAIN_TEST=1 to run Keychain tests."
    )
    testBaseURL = "https://test.invalid/\(UUID().uuidString)"
  }

  override func tearDownWithError() throws {
    if let url = testBaseURL {
      try? RemoteAICredentials.delete(baseURL: url)
    }
  }

  func testWriteReadUpdateDeleteHasKey() throws {
    XCTAssertFalse(RemoteAICredentials.hasKey(baseURL: testBaseURL))
    XCTAssertNil(RemoteAICredentials.read(baseURL: testBaseURL))

    try RemoteAICredentials.save("first-secret", baseURL: testBaseURL)
    XCTAssertTrue(RemoteAICredentials.hasKey(baseURL: testBaseURL))
    XCTAssertEqual(RemoteAICredentials.read(baseURL: testBaseURL), "first-secret")

    try RemoteAICredentials.save("second-secret", baseURL: testBaseURL)
    XCTAssertEqual(RemoteAICredentials.read(baseURL: testBaseURL), "second-secret")

    try RemoteAICredentials.delete(baseURL: testBaseURL)
    XCTAssertFalse(RemoteAICredentials.hasKey(baseURL: testBaseURL))
    XCTAssertNil(RemoteAICredentials.read(baseURL: testBaseURL))
  }
}
