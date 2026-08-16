import Foundation

struct ActionBatch: Decodable, Sendable {
    let actions: [KeynoteAction]
}

struct KeynoteAction: Decodable, Sendable {
    let op: String
    let text: String?
    let position: ActionPosition?
    let layout: String?
    let slideIndex: Int?
    let itemIndex: Int?
    let skipped: Bool?
    let theme: String?
    let width: Double?
    let height: Double?
    let x: Double?
    let y: Double?
    let shape: String?

    enum CodingKeys: String, CodingKey {
        case op, text, position, layout, skipped, theme, width, height, x, y, shape
        case slideIndex = "slide_index"
        case itemIndex = "item_index"
    }
}

enum ActionPosition: Decodable, Sendable {
    case named(String)
    case index(Int)

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let value = try? container.decode(Int.self) {
            self = .index(value)
            return
        }
        if let value = try? container.decode(String.self) {
            self = .named(value)
            return
        }
        throw DecodingError.typeMismatch(
            ActionPosition.self,
            .init(codingPath: decoder.codingPath, debugDescription: "Expected string or int position")
        )
    }

    var description: String {
        switch self {
        case .named(let name): return name
        case .index(let index): return String(index)
        }
    }
}

struct ActionResult: Sendable {
    let op: String
    let success: Bool
    let detail: String
}
