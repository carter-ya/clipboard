import XCTest

@testable import ClipboardCore

final class FilterChainTests: XCTestCase {
  private let context = ClipContext(sourceBundleID: nil, changeCount: 1, timestamp: Date())
  private let sampleItem = RawClipItem()

  func testAllAcceptReturnsAccept() {
    let chain = FilterChain(filters: [
      AlwaysAcceptFilter(),
      AlwaysAcceptFilter(),
    ])
    XCTAssertEqual(chain.evaluate(sampleItem, context: context), .accept)
  }

  func testEmptyChainReturnsAccept() {
    let chain = FilterChain(filters: [])
    XCTAssertEqual(chain.evaluate(sampleItem, context: context), .accept)
  }

  func testFirstRejectShortCircuits() {
    let tail = CountingFilter(decision: .reject("noop"))
    let chain = FilterChain(filters: [
      CountingFilter(decision: .reject("tooLarge")),
      tail,
    ])
    XCTAssertEqual(chain.evaluate(sampleItem, context: context), .reject("tooLarge"))
    XCTAssertEqual(tail.evaluations, 0, "filters after first .reject must not evaluate")
  }

  func testFirstMarkSensitiveShortCircuits() {
    let tail = CountingFilter(decision: .reject("noop"))
    let chain = FilterChain(filters: [
      CountingFilter(decision: .markSensitive("concealedType")),
      tail,
    ])
    XCTAssertEqual(chain.evaluate(sampleItem, context: context), .markSensitive("concealedType"))
    XCTAssertEqual(tail.evaluations, 0, "filters after first .markSensitive must not evaluate")
  }

  func testOrderPreserved() {
    let size = CountingFilter(decision: .accept)
    let sens = CountingFilter(decision: .markSensitive("x"))
    let block = CountingFilter(decision: .reject("y"))
    let chain = FilterChain(filters: [size, sens, block])
    XCTAssertEqual(chain.evaluate(sampleItem, context: context), .markSensitive("x"))
    XCTAssertEqual(size.evaluations, 1)
    XCTAssertEqual(sens.evaluations, 1)
    XCTAssertEqual(block.evaluations, 0)
  }
}

private struct AlwaysAcceptFilter: ClipFilter {
  func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision { .accept }
}

private final class CountingFilter: ClipFilter, @unchecked Sendable {
  let decision: FilterDecision
  private(set) var evaluations: Int = 0

  init(decision: FilterDecision) {
    self.decision = decision
  }

  func evaluate(_ item: RawClipItem, context: ClipContext) -> FilterDecision {
    evaluations += 1
    return decision
  }
}
