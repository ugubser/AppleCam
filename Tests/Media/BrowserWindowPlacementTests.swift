import XCTest
@testable import AppleCamMedia

final class BrowserWindowPlacementTests: XCTestCase {
    private let main = CGRect(x: 0, y: 0, width: 2560, height: 1440)
    private let left = CGRect(x: -1920, y: 200, width: 1920, height: 1080)

    func testInteractiveWindowIsCentredOnAppleCamsScreen() {
        let frame = BrowserWindowPlacement.interactiveFrame(size: CGSize(width: 1280, height: 748), remembered: nil, screens: [main, left], preferred: left)
        XCTAssertEqual(frame, CGRect(x: -1920 + 320, y: 200 + 166, width: 1280, height: 748))
        XCTAssertEqual(BrowserWindowPlacement.interactiveFrame(size: CGSize(width: 100, height: 100), remembered: nil, screens: [main], preferred: nil).midX, main.midX)
    }

    func testInteractiveWindowReopensWhereItWasLeftWhileThatIsOnAScreen() {
        let size = CGSize(width: 1280, height: 748)
        let kept = BrowserWindowPlacement.interactiveFrame(size: size, remembered: CGPoint(x: 300, y: 100), screens: [main], preferred: main)
        XCTAssertEqual(kept.origin, CGPoint(x: 300, y: 100))
        // A spot whose title bar is no longer on any screen (a screen was removed) is not reused.
        let lost = BrowserWindowPlacement.interactiveFrame(size: size, remembered: CGPoint(x: -1500, y: 400), screens: [main], preferred: main)
        XCTAssertEqual(lost, CGRect(x: 640, y: 346, width: 1280, height: 748))
    }

    func testTallWindowKeepsItsTitleBarOnScreen() {
        let small = CGRect(x: 0, y: 0, width: 1440, height: 875)
        let frame = BrowserWindowPlacement.interactiveFrame(size: CGSize(width: 1920, height: 1108), remembered: nil, screens: [small], preferred: small)
        XCTAssertEqual(frame.maxY, small.maxY)
        XCTAssertEqual(frame.minX, 0)
    }
}
