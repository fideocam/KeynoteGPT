import Foundation

/// Escapes untrusted strings for embedding inside single-quoted JXA/JavaScript literals.
enum JSStringEscaper {
    /// Maximum length accepted for model-supplied string fields before apply.
    static let maxFieldLength = 8_000

    static func escapeForSingleQuotedJS(_ value: String) -> String {
        var out = ""
        out.reserveCapacity(value.utf16.count + 8)
        for scalar in value.unicodeScalars {
            switch scalar.value {
            case 0x5C: out += "\\\\" // \
            case 0x27: out += "\\'" // '
            case 0x22: out += "\\\"" // "
            case 0x0A: out += "\\n"
            case 0x0D: out += "\\r"
            case 0x09: out += "\\t"
            case 0x08: out += "\\b"
            case 0x0C: out += "\\f"
            case 0x00: out += "\\0"
            case 0x2028: out += "\\u2028" // line separator — can terminate JS strings
            case 0x2029: out += "\\u2029" // paragraph separator
            case 0x01...0x1F:
                out += String(format: "\\u%04x", scalar.value)
            default:
                out.append(String(scalar))
            }
        }
        return out
    }

    /// Returns nil when the field is too large or contains disallowed control characters.
    static func validatedField(_ value: String?, maxLength: Int = maxFieldLength) -> String? {
        guard let value else { return nil }
        guard value.count <= maxLength else { return nil }
        guard !containsDisallowedControlCharacters(value) else { return nil }
        return value
    }

    /// True when escaping alone is insufficient / field should be rejected.
    static func containsDisallowedControlCharacters(_ value: String) -> Bool {
        value.unicodeScalars.contains { scalar in
            switch scalar.value {
            case 0x00: return true
            default: return false
            }
        }
    }
}
