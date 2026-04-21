import XCTest

@testable import ClipboardCore

final class PlaceholderTests: XCTestCase {
  func testFilterDecisionEquality() {
    XCTAssertEqual(FilterDecision.accept, FilterDecision.accept)
    XCTAssertEqual(FilterDecision.reject("x"), FilterDecision.reject("x"))
    XCTAssertNotEqual(FilterDecision.reject("x"), FilterDecision.reject("y"))
    XCTAssertNotEqual(FilterDecision.accept, FilterDecision.markSensitive("x"))
  }
}
