import XCTest
@testable import KeynoteGPT

final class ThemePaletteTests: XCTestCase {
    func testAccentsAreDistinctAndNotBlack() {
        let colors = ThemePalette.presentationAccents
        XCTAssertGreaterThanOrEqual(colors.count, 7)
        for (i, color) in colors.enumerated() {
            XCTAssertFalse(ThemePalette.isNearBlack(color), "accent \(i) is near black")
        }
        let keys = Set(colors.map { "\($0.r),\($0.g),\($0.b)" })
        XCTAssertEqual(keys.count, colors.count)
    }

    func testCyclesThroughPalette() {
        let a = ThemePalette.color(at: 0)
        let b = ThemePalette.color(at: ThemePalette.presentationAccents.count)
        XCTAssertEqual(a, b)
        XCTAssertNotEqual(ThemePalette.color(at: 0), ThemePalette.color(at: 1))
    }

    func testHarvestedPalettePreferredWhenRichEnough() {
        let harvested = [
            ThemePalette.RGB(r: 10000, g: 20000, b: 30000),
            ThemePalette.RGB(r: 30000, g: 10000, b: 20000),
            ThemePalette.RGB(r: 20000, g: 30000, b: 10000),
            ThemePalette.RGB(r: 0, g: 0, b: 0), // ignored near-black
        ]
        let resolved = ThemePalette.resolvePalette(harvested: harvested)
        XCTAssertEqual(resolved.count, 3)
        XCTAssertFalse(resolved.contains(where: ThemePalette.isNearBlack))
    }

    func testFallbackWhenHarvestSparse() {
        let resolved = ThemePalette.resolvePalette(harvested: [ThemePalette.RGB(r: 1000, g: 1000, b: 1000)])
        XCTAssertEqual(resolved, ThemePalette.presentationAccents)
    }

    func testContrastingText() {
        let dark = ThemePalette.RGB(r: 5000, g: 8000, b: 12000)
        let light = ThemePalette.RGB(r: 60000, g: 60000, b: 60000)
        XCTAssertTrue(dark.contrastingText.r > 50000)
        XCTAssertTrue(light.contrastingText.r < 10000)
    }
}
