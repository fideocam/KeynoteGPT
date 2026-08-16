import XCTest
@testable import KeynoteGPT

final class BoxLayoutTests: XCTestCase {
    func testSevenBoxesUseFourColumnsByDefault() {
        XCTAssertEqual(BoxLayout.preferredColumns(for: 7), 4)
        let rects = BoxLayout.grid(count: 7)
        XCTAssertEqual(rects.count, 7)
        // First row: 4 boxes, second row starts lower
        XCTAssertEqual(rects[0].y, rects[3].y, accuracy: 0.01)
        XCTAssertGreaterThan(rects[4].y, rects[0].y)
        XCTAssertGreaterThan(rects[0].width, 100)
        XCTAssertGreaterThan(rects[0].height, 80)
    }

    func testExplicitColumnsRespected() {
        let rects = BoxLayout.grid(count: 6, columns: 3)
        XCTAssertEqual(rects.count, 6)
        XCTAssertEqual(rects[0].y, rects[2].y, accuracy: 0.01)
        XCTAssertGreaterThan(rects[3].y, rects[0].y)
    }

    func testJXAShapeTypeMapping() {
        XCTAssertEqual(BoxLayout.jxaShapeType(from: "rounded_rectangle"), "rounded rectangle")
        XCTAssertEqual(BoxLayout.jxaShapeType(from: "oval"), "oval")
        XCTAssertEqual(BoxLayout.jxaShapeType(from: nil), "rounded rectangle")
    }
}
