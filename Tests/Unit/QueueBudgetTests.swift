import XCTest
@testable import AppleCamCore

final class QueueBudgetTests: XCTestCase {
    func testBriefBackpressureDropsWithoutAccumulatingFrames() {
        var budget = QueueBudget()
        XCTAssertEqual(budget.decision(depth: 0, now: 10), .enqueue)
        XCTAssertEqual(budget.decision(depth: 1, now: 10.03), .enqueue)
        XCTAssertEqual(budget.decision(depth: 2, now: 10.06), .drop)
        XCTAssertEqual(budget.decision(depth: 2, now: 10.09), .drop)
        XCTAssertEqual(budget.decision(depth: 1, now: 10.12), .enqueue)
    }
    func testStalledSinkFailsInsteadOfDroppingForever() {
        var budget = QueueBudget()
        XCTAssertEqual(budget.decision(depth: 2, now: 10), .drop)
        XCTAssertEqual(budget.decision(depth: 2, now: 11.99), .drop)
        XCTAssertEqual(budget.decision(depth: 2, now: 12), .stalled)
    }
    func testDrainResetsStallDeadline() {
        var budget = QueueBudget()
        _ = budget.decision(depth: 2, now: 10)
        _ = budget.decision(depth: 0, now: 11)
        XCTAssertEqual(budget.decision(depth: 2, now: 12), .drop)
        XCTAssertEqual(budget.decision(depth: 2, now: 13), .drop)
    }
}
