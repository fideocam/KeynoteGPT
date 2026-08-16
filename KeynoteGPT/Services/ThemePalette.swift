import Foundation

/// Accent colors used when Keynote scripting cannot set shape fills.
/// Values are AppleScript RGB components in 0…65535.
enum ThemePalette {
    struct RGB: Equatable {
        let r: Int
        let g: Int
        let b: Int

        var appleScriptTuple: String { "{\(r), \(g), \(b)}" }

        /// Approximate luminance for choosing white vs dark text.
        var isDark: Bool {
            let rr = Double(r) / 65535.0
            let gg = Double(g) / 65535.0
            let bb = Double(b) / 65535.0
            return (0.2126 * rr + 0.7152 * gg + 0.0722 * bb) < 0.55
        }

        var contrastingText: RGB {
            isDark ? RGB(r: 65535, g: 65535, b: 65535) : RGB(r: 20, g: 20, b: 20)
        }
    }

    /// Keynote-like accent set (similar to Basic Color / colorful themes). Avoids pure black.
    static let presentationAccents: [RGB] = [
        RGB(r: 0x1F * 257, g: 0x77 * 257, b: 0xB4 * 257), // blue
        RGB(r: 0xFF * 257, g: 0x7F * 257, b: 0x0E * 257), // orange
        RGB(r: 0x2C * 257, g: 0xA0 * 257, b: 0x2C * 257), // green
        RGB(r: 0xD6 * 257, g: 0x27 * 257, b: 0x28 * 257), // red
        RGB(r: 0x94 * 257, g: 0x67 * 257, b: 0xBD * 257), // purple
        RGB(r: 0x8C * 257, g: 0x56 * 257, b: 0x4B * 257), // brown
        RGB(r: 0xE3 * 257, g: 0x77 * 257, b: 0xC2 * 257), // pink
        RGB(r: 0x17 * 257, g: 0xBE * 257, b: 0xCF * 257), // cyan
        RGB(r: 0xBC * 257, g: 0xBD * 257, b: 0x22 * 257), // olive
        RGB(r: 0x7F * 257, g: 0x7F * 257, b: 0x7F * 257), // gray (last resort, still not black)
    ]

    static let emptyCell = RGB(r: 0xF2 * 257, g: 0xF2 * 257, b: 0xF2 * 257)

    static func color(at index: Int, from palette: [RGB] = presentationAccents) -> RGB {
        guard !palette.isEmpty else { return presentationAccents[0] }
        return palette[index % palette.count]
    }

    /// Prefer harvested document colors when available; otherwise built-in accents.
    static func resolvePalette(harvested: [RGB]) -> [RGB] {
        let filtered = harvested.filter { !isNearBlack($0) && !isNearWhite($0) }
        if filtered.count >= 3 { return filtered }
        return presentationAccents
    }

    static func isNearBlack(_ c: RGB) -> Bool {
        c.r < 4000 && c.g < 4000 && c.b < 4000
    }

    static func isNearWhite(_ c: RGB) -> Bool {
        c.r > 60000 && c.g > 60000 && c.b > 60000
    }
}
