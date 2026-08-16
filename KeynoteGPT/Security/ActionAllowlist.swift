import Foundation

/// Allowlist of ops the companion will execute. Anything else is dropped before JXA.
enum ActionAllowlist {
    static let maxLabels = 40
    static let maxLabelLength = 200

    static let allowedOps: Set<String> = [
        "note",
        "add_slide",
        "add_content_slide",
        "add_labeled_shape",
        "add_labeled_boxes",
        "delete_slide",
        "duplicate_slide",
        "set_title",
        "set_body",
        "set_presenter_notes",
        "add_text_box",
        "set_text_item",
        "add_shape",
        "set_slide_skipped",
        "select_slide",
        "create_presentation",
    ]

    static let allowedShapes: Set<String> = [
        "rectangle", "oval", "circle", "ellipse",
        "rounded_rectangle", "round_rect", "rounded",
    ]

    static func isAllowed(_ op: String) -> Bool {
        allowedOps.contains(op)
    }

    /// Filters unknown ops and rejects actions with oversized / null-laden string fields.
    static func sanitize(_ actions: [KeynoteAction]) -> (kept: [KeynoteAction], rejected: [String]) {
        var kept: [KeynoteAction] = []
        var rejected: [String] = []

        for action in actions {
            if !isAllowed(action.op) {
                rejected.append("blocked unknown op '\(action.op)'")
                continue
            }
            if let reason = rejectionReason(for: action) {
                rejected.append("blocked \(action.op): \(reason)")
                continue
            }
            kept.append(action)
        }
        return (kept, rejected)
    }

    static func rejectionReason(for action: KeynoteAction) -> String? {
        let stringFields: [(String, String?)] = [
            ("text", action.text),
            ("title", action.title),
            ("body", action.body),
            ("layout", action.layout),
            ("theme", action.theme),
            ("shape", action.shape),
        ]
        for (name, value) in stringFields {
            guard let value else { continue }
            if value.count > JSStringEscaper.maxFieldLength {
                return "\(name) exceeds \(JSStringEscaper.maxFieldLength) characters"
            }
            if JSStringEscaper.containsDisallowedControlCharacters(value) {
                return "\(name) contains NUL bytes"
            }
        }

        if let position = action.position, case .named(let name) = position {
            if name.count > 200 {
                return "position name too long"
            }
            if JSStringEscaper.containsDisallowedControlCharacters(name) {
                return "position contains NUL bytes"
            }
            let allowedPositions: Set<String> = ["end", "beginning", "after_current"]
            if !allowedPositions.contains(name), Int(name) == nil {
                return "unsupported position '\(name)'"
            }
        }

        if let shape = action.shape, !allowedShapes.contains(shape.lowercased()) {
            return "unsupported shape '\(shape)'"
        }

        if let labels = action.labels {
            if labels.isEmpty {
                return "labels must not be empty"
            }
            if labels.count > maxLabels {
                return "labels exceeds \(maxLabels) items"
            }
            for (i, label) in labels.enumerated() {
                if label.count > maxLabelLength {
                    return "labels[\(i)] exceeds \(maxLabelLength) characters"
                }
                if JSStringEscaper.containsDisallowedControlCharacters(label) {
                    return "labels[\(i)] contains NUL bytes"
                }
            }
        }

        if action.op == "add_labeled_boxes", action.labels == nil || action.labels?.isEmpty == true {
            return "labels required"
        }

        if let columns = action.columns, !(1...8).contains(columns) {
            return "columns must be 1…8"
        }

        return nil
    }
}
