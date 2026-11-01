import XCTest

@testable import ClipboardCore

final class DesktopSizeLimitTests: XCTestCase {
  func testFractionalAndLargeThresholdsRemainExact() {
    XCTAssertEqual(DesktopSizeLimit.bytes(fromMiB: " 0.5 "), 524288)
    XCTAssertEqual(DesktopSizeLimit.bytes(fromMiB: "32.5"), 34_078_720)
    XCTAssertEqual(DesktopSizeLimit.bytes(fromMiB: "0.1"), 104857)
    XCTAssertEqual(DesktopSizeLimit.bytes(fromMiB: "0"), 0)
    for bytes in [0, 1, 104857, 524288, 34_078_720, Int.max] {
      XCTAssertEqual(
        DesktopSizeLimit.bytes(fromMiB: DesktopSizeLimit.mibString(forBytes: bytes)), bytes)
    }
  }
  func testMalformedOverflowAndSubByteInputsCannotDisableTheFilter() {
    for text in [
      "", ".", "-1", "NaN", "Infinity", "1e6", "1,5", "1.2.3", "0.0000001",
      String(repeating: "9", count: 64),
    ] {
      XCTAssertNil(DesktopSizeLimit.bytes(fromMiB: text))
    }
  }
  func testLargePolicyRoundTripsIndependentlyOfTheNativeTransferCap() throws {
    var settings = DesktopSettings()
    settings.maxClipSizeBytes = 34_078_720
    try settings.validate()
    let decoded = try JSONDecoder().decode(
      DesktopSettings.self, from: JSONEncoder().encode(settings))
    XCTAssertEqual(decoded.maxClipSizeBytes, settings.maxClipSizeBytes)
    settings.maxClipSizeBytes = -1
    XCTAssertThrowsError(try settings.validate())
  }
}
