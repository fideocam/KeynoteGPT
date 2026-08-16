import Foundation

enum PromptLoader {
    static func buildSystemPrompt() -> String {
        let rules = loadResource("system_prompt_rules", ext: "txt")
        let schema = loadResource("action_schema", ext: "txt")
        return rules + "\n\n\n=== Action schema ===\n\n" + schema
    }

    static func buildUserMessage(digest: String, userPrompt: String) -> String {
        """
        === Presentation digest ===
        \(digest.trimmingCharacters(in: .whitespacesAndNewlines))

        === User request ===
        \(userPrompt.trimmingCharacters(in: .whitespacesAndNewlines))
        """
    }

    private static func loadResource(_ name: String, ext: String) -> String {
        if let url = Bundle.main.url(forResource: name, withExtension: ext),
           let text = try? String(contentsOf: url, encoding: .utf8) {
            return text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
        // Fallback for tests / unbundled runs: look next to sources.
        let candidates = [
            URL(fileURLWithPath: #filePath)
                .deletingLastPathComponent()
                .deletingLastPathComponent()
                .appendingPathComponent("Prompts/\(name).\(ext)"),
        ]
        for url in candidates {
            if let text = try? String(contentsOf: url, encoding: .utf8) {
                return text.trimmingCharacters(in: .whitespacesAndNewlines)
            }
        }
        return "(missing prompt file \(name).\(ext))"
    }
}
