import XCTest
import AppleCamCore
@testable import AppleCamMedia

final class FieldFormatTests: XCTestCase {
    private let us = Locale(identifier: "en_US"), swiss = Locale(identifier: "de_CH")
    func testParsesNumbersAndRejectsEmptyOrNonNumericText() {
        XCTAssertEqual(FieldFormat.number(from: "50", locale: us), 50)
        XCTAssertEqual(FieldFormat.number(from: " 12.5 ", locale: us), 12.5)
        XCTAssertEqual(FieldFormat.number(from: "-3", locale: us), -3)
        XCTAssertNil(FieldFormat.number(from: "", locale: us))
        XCTAssertNil(FieldFormat.number(from: "   ", locale: us))
        XCTAssertNil(FieldFormat.number(from: "abc", locale: us))
    }
    func testFormatsWithoutGroupingSoValuesRoundTrip() {
        XCTAssertEqual(FieldFormat.string(1920, fractionDigits: 0...0, locale: us), "1920")
        XCTAssertEqual(FieldFormat.string(1920, fractionDigits: 0...0, locale: swiss), "1920")
        XCTAssertEqual(FieldFormat.string(12.346, locale: us), "12.35")
        XCTAssertEqual(FieldFormat.string(25, locale: us), "25")
        XCTAssertEqual(FieldFormat.number(from: FieldFormat.string(29.97, fractionDigits: 0...3, locale: swiss), locale: swiss), 29.97)
    }
    func testIntegerParsingRejectsFractions() {
        XCTAssertEqual(FieldFormat.integer(from: "1280", locale: us), 1280)
        XCTAssertNil(FieldFormat.integer(from: "12.5", locale: us))
        XCTAssertNil(FieldFormat.integer(from: "", locale: us))
    }
}

final class LayerGeometryTests: XCTestCase {
    private let canvas = CGSize(width: 200, height: 100)
    func testMoveUsesCanvasUnitsAndClamps() {
        let start = LayerPlacement()
        let moved = LayerGeometry.moved(start, by: CGSize(width: 50, height: -25), canvas: canvas)
        XCTAssertEqual(moved.x, 0.25); XCTAssertEqual(moved.y, -0.25); XCTAssertEqual(moved.width, 1)
        XCTAssertEqual(LayerGeometry.moved(start, by: CGSize(width: 1e6, height: 0), canvas: canvas).x, 10)
    }
    func testMoveIsRelativeToGestureStartNotPreviousUpdate() {
        // Repeated updates with growing translation from the same start must not accumulate.
        let start = LayerPlacement()
        var latest = start
        for step in 1...5 { latest = LayerGeometry.moved(start, by: CGSize(width: Double(step) * 10, height: 0), canvas: canvas) }
        XCTAssertEqual(latest.x, 0.25, accuracy: 1e-12)
    }
    func testResizeKeepsAspectWhenLocked() {
        var start = LayerPlacement(); start.width = 0.5; start.height = 0.5
        let locked = LayerGeometry.resized(start, by: CGSize(width: 50, height: 5), canvas: canvas)
        XCTAssertEqual(locked.width, 0.75, accuracy: 1e-12); XCTAssertEqual(locked.height, 0.75, accuracy: 1e-12)
        start.aspectLocked = false
        let free = LayerGeometry.resized(start, by: CGSize(width: 50, height: 5), canvas: canvas)
        XCTAssertEqual(free.width, 0.75, accuracy: 1e-12); XCTAssertEqual(free.height, 0.55, accuracy: 1e-12)
        XCTAssertEqual(LayerGeometry.resized(start, by: CGSize(width: -1e6, height: 0), canvas: canvas).width, 0.001)
    }
    func testResizeFromTopLeadingKeepsOppositeCornerFixed() {
        var start = LayerPlacement(); start.x = 0.25; start.y = 0.25; start.width = 0.5; start.height = 0.5; start.aspectLocked = false
        // Dragging the top-left handle up and left by 20 % of the canvas grows the layer toward the top left.
        let grown = LayerGeometry.resized(start, by: CGSize(width: -40, height: -20), canvas: canvas, from: .topLeading)
        XCTAssertEqual(grown.width, 0.7, accuracy: 1e-12); XCTAssertEqual(grown.height, 0.7, accuracy: 1e-12)
        XCTAssertEqual(grown.x + grown.width, 0.75, accuracy: 1e-12); XCTAssertEqual(grown.y + grown.height, 0.75, accuracy: 1e-12)
        let mixed = LayerGeometry.resized(start, by: CGSize(width: 40, height: -20), canvas: canvas, from: .topTrailing)
        XCTAssertEqual(mixed.x, 0.25); XCTAssertEqual(mixed.width, 0.7, accuracy: 1e-12)
        XCTAssertEqual(mixed.y + mixed.height, 0.75, accuracy: 1e-12)
        start.aspectLocked = true
        let locked = LayerGeometry.resized(start, by: CGSize(width: 20, height: 0), canvas: canvas, from: .bottomLeading)
        XCTAssertEqual(locked.width, 0.4, accuracy: 1e-12); XCTAssertEqual(locked.height, 0.4, accuracy: 1e-12)
        XCTAssertEqual(locked.x + locked.width, 0.75, accuracy: 1e-12); XCTAssertEqual(locked.y, 0.25)
    }
    func testVisibleRectIsClippedToCanvas() {
        var placement = LayerPlacement(); placement.x = -0.25; placement.y = -0.25; placement.width = 1.25; placement.height = 1.25
        XCTAssertEqual(LayerGeometry.visibleRect(placement, canvas: canvas), CGRect(x: 0, y: 0, width: 200, height: 100))
        placement.x = 2
        XCTAssertNil(LayerGeometry.visibleRect(placement, canvas: canvas), "A layer entirely off the canvas has no frame")
    }
    func testClickSelectsTopmostThenCyclesToLayersUnderneath() {
        var cover = SceneLayer(name: "Webcam", source: .camera); cover.placement.x = -0.2; cover.placement.width = 1.4
        var small = SceneLayer(name: "Browser", source: .camera); small.placement.width = 0.5; small.placement.height = 0.5
        var hidden = SceneLayer(name: "Hidden", source: .camera); hidden.visible = false
        let background = SceneLayer(name: "Background", source: .camera)
        let layers = [cover, small, hidden, background] // top first
        let point = CGPoint(x: 20, y: 20)
        XCTAssertEqual(LayerGeometry.layer(at: point, in: layers, canvas: canvas, selected: nil), cover.id)
        XCTAssertEqual(LayerGeometry.layer(at: point, in: layers, canvas: canvas, selected: cover.id), small.id)
        XCTAssertEqual(LayerGeometry.layer(at: point, in: layers, canvas: canvas, selected: small.id), background.id)
        XCTAssertEqual(LayerGeometry.layer(at: point, in: layers, canvas: canvas, selected: background.id), cover.id)
        // Outside the small layer, clicking the selected small layer's area is impossible; others cycle among themselves.
        XCTAssertEqual(LayerGeometry.layer(at: CGPoint(x: 150, y: 80), in: layers, canvas: canvas, selected: small.id), cover.id)
        XCTAssertNil(LayerGeometry.layer(at: CGPoint(x: 150, y: 80), in: [small], canvas: canvas, selected: nil))
    }
    func testInspectorSizeKeepsAspectWhenLocked() {
        var start = LayerPlacement(); start.width = 0.4; start.height = 0.2
        let wider = LayerGeometry.sized(start, width: 0.8)
        XCTAssertEqual(wider.width, 0.8); XCTAssertEqual(wider.height, 0.4, accuracy: 1e-12)
        start.aspectLocked = false
        XCTAssertEqual(LayerGeometry.sized(start, height: 0.5).width, 0.4)
    }
}

final class DraftBufferTests: XCTestCase {
    func testUntouchedDraftFollowsOutsideChangesAndIsNotEdited() {
        var buffer = DraftBuffer("50")
        buffer.modelChanged(to: "61.59") // e.g. a canvas resize while the field still has focus
        XCTAssertEqual(buffer.draft, "61.59"); XCTAssertFalse(buffer.isEdited, "An untouched field must never apply a stale value")
    }
    func testTypedDraftSurvivesOutsideChangesUntilApplied() {
        var buffer = DraftBuffer("50")
        buffer.draft = "7"
        buffer.modelChanged(to: "61.59")
        XCTAssertEqual(buffer.draft, "7"); XCTAssertTrue(buffer.isEdited)
        buffer.show("7"); XCTAssertFalse(buffer.isEdited)
    }
    func testClearingTheFieldIsAnEditNotARejection() {
        var buffer = DraftBuffer("Webcam")
        buffer.draft = ""
        XCTAssertTrue(buffer.isEdited); XCTAssertEqual(buffer.draft, "")
        buffer.draft = "P"
        XCTAssertEqual(buffer.draft, "P", "Typing after clearing keeps only the new text")
    }
}
