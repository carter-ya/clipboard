import XCTest

@testable import ClipboardCore

final class HashingTests: XCTestCase {

  func testSameTextAcrossDifferentUTIMetadataHashesIdentically() {
    let text = Data("hello".utf8)
    let lean = [RawPayload(pasteboardType: "public.utf8-plain-text", data: text)]
    let decorated = [
      RawPayload(pasteboardType: "public.utf8-plain-text", data: text),
      RawPayload(pasteboardType: "NSStringPboardType", data: text),
      RawPayload(pasteboardType: "com.apple.webarchive", data: Data("junk".utf8)),
    ]
    XCTAssertEqual(Hashing.sha256(of: lean), Hashing.sha256(of: decorated))
  }

  func testDifferentTextHashesDiffer() {
    let a = [RawPayload(pasteboardType: "public.utf8-plain-text", data: Data("a".utf8))]
    let b = [RawPayload(pasteboardType: "public.utf8-plain-text", data: Data("b".utf8))]
    XCTAssertNotEqual(Hashing.sha256(of: a), Hashing.sha256(of: b))
  }

  func testImageWinsOverTextWhenBothPresent() {
    let imageBytes = Data(repeating: 0xAB, count: 16)
    let onlyImage = [RawPayload(pasteboardType: "public.png", data: imageBytes)]
    let imagePlusText = [
      RawPayload(pasteboardType: "public.png", data: imageBytes),
      RawPayload(pasteboardType: "public.utf8-plain-text", data: Data("alt".utf8)),
    ]
    XCTAssertEqual(Hashing.sha256(of: onlyImage), Hashing.sha256(of: imagePlusText))
  }

  func testRTFPreferredOverText() {
    let rtfBytes = Data("{\\rtf1 hi}".utf8)
    let pair1 = [
      RawPayload(pasteboardType: "public.rtf", data: rtfBytes),
      RawPayload(pasteboardType: "public.utf8-plain-text", data: Data("hi".utf8)),
    ]
    let pair2 = [
      RawPayload(pasteboardType: "public.rtf", data: rtfBytes),
      RawPayload(pasteboardType: "public.utf8-plain-text", data: Data("different".utf8)),
    ]
    XCTAssertEqual(Hashing.sha256(of: pair1), Hashing.sha256(of: pair2))
  }

  func testFallbackWhenNoPrimaryType() {
    let one = [RawPayload(pasteboardType: "com.opaque.custom", data: Data("x".utf8))]
    let two = [RawPayload(pasteboardType: "com.opaque.custom", data: Data("y".utf8))]
    XCTAssertNotEqual(Hashing.sha256(of: one), Hashing.sha256(of: two))
  }
}
