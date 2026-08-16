import Foundation

enum BoxLayout {
    struct Rect: Equatable {
        let x: Double
        let y: Double
        let width: Double
        let height: Double
    }

    /// Lays out `count` boxes in a grid inside the content area under a title band.
    static func grid(
        count: Int,
        columns requestedColumns: Int? = nil,
        slideWidth: Double = 1920,
        slideHeight: Double = 1080,
        topReserved: Double = 200,
        margin: Double = 80,
        gap: Double = 28
    ) -> [Rect] {
        guard count > 0 else { return [] }
        let columns = max(1, requestedColumns ?? preferredColumns(for: count))
        let rows = Int(ceil(Double(count) / Double(columns)))
        let usableWidth = max(40, slideWidth - (margin * 2))
        let usableHeight = max(40, slideHeight - topReserved - margin)
        let boxWidth = (usableWidth - (gap * Double(columns - 1))) / Double(columns)
        let boxHeight = (usableHeight - (gap * Double(rows - 1))) / Double(rows)

        var rects: [Rect] = []
        for i in 0..<count {
            let col = i % columns
            let row = i / columns
            let x = margin + (Double(col) * (boxWidth + gap))
            let y = topReserved + (Double(row) * (boxHeight + gap))
            rects.append(Rect(x: x, y: y, width: boxWidth, height: boxHeight))
        }
        return rects
    }

    static func preferredColumns(for count: Int) -> Int {
        switch count {
        case 1: return 1
        case 2: return 2
        case 3: return 3
        case 4: return 2
        case 5, 6: return 3
        case 7, 8: return 4
        case 9: return 3
        default: return min(4, max(3, Int(ceil(sqrt(Double(count))))))
        }
    }

    static func jxaShapeType(from shape: String?) -> String {
        switch (shape ?? "rounded_rectangle").lowercased() {
        case "oval", "circle", "ellipse": return "oval"
        case "rectangle", "rect": return "rectangle"
        default: return "rounded rectangle"
        }
    }
}
