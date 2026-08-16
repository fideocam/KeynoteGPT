import Foundation

enum ActionParser {
    static func extractActions(from assistantText: String) -> [KeynoteAction] {
        let raw = extractRawActions(from: assistantText)
        return ActionAllowlist.sanitize(raw).kept
    }

    /// Like `extractActions`, but also returns what the allowlist rejected (for UI / tests).
    static func extractActionsDetailed(from assistantText: String) -> (kept: [KeynoteAction], rejected: [String]) {
        let raw = extractRawActions(from: assistantText)
        return ActionAllowlist.sanitize(raw)
    }

    static func looksLikeAnalysis(_ text: String) -> Bool {
        extractActions(from: text).isEmpty
    }

    private static func extractRawActions(from assistantText: String) -> [KeynoteAction] {
        let stripped = stripMarkdownFences(assistantText.trimmingCharacters(in: .whitespacesAndNewlines))
        if let batch = decodeBatch(stripped) {
            return batch.actions
        }

        // Scan for the last JSON object containing "actions".
        var last: [KeynoteAction] = []
        let decoder = JSONDecoder()
        var index = stripped.startIndex
        while index < stripped.endIndex {
            if stripped[index] == "{" {
                let substring = String(stripped[index...])
                if let data = substring.data(using: .utf8),
                   let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                   obj["actions"] is [Any],
                   let rebuilt = try? JSONSerialization.data(withJSONObject: obj),
                   let batch = try? decoder.decode(ActionBatch.self, from: rebuilt) {
                    last = batch.actions
                } else if let batch = decodePartialObject(from: substring) {
                    last = batch.actions
                }
            }
            index = stripped.index(after: index)
        }
        return last
    }

    private static func decodeBatch(_ text: String) -> ActionBatch? {
        guard let data = text.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(ActionBatch.self, from: data)
    }

    private static func decodePartialObject(from text: String) -> ActionBatch? {
        var depth = 0
        var started = false
        var end = text.startIndex
        var inString = false
        var escaped = false

        for i in text.indices {
            let ch = text[i]
            if inString {
                if escaped {
                    escaped = false
                } else if ch == "\\" {
                    escaped = true
                } else if ch == "\"" {
                    inString = false
                }
                continue
            }
            switch ch {
            case "\"":
                inString = true
            case "{":
                depth += 1
                started = true
            case "}":
                depth -= 1
                if started && depth == 0 {
                    end = text.index(after: i)
                    let slice = String(text[text.startIndex..<end])
                    return decodeBatch(slice)
                }
            default:
                break
            }
        }
        return nil
    }

    private static func stripMarkdownFences(_ text: String) -> String {
        guard text.contains("```") else { return text }
        var chunks: [String] = []
        for part in text.split(separator: "```", omittingEmptySubsequences: false).map(String.init) {
            var chunk = part.trimmingCharacters(in: .whitespacesAndNewlines)
            if chunk.lowercased().hasPrefix("json") {
                chunk = String(chunk.dropFirst(4)).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !chunk.isEmpty { chunks.append(chunk) }
        }
        return chunks.last ?? text
    }
}
