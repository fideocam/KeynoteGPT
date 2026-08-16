import Foundation

@MainActor
final class AgentOrchestrator: ObservableObject {
    @Published var messages: [ChatMessage] = []
    @Published var isBusy = false
    @Published var statusText: String = "Ready"
    @Published var lastError: String?

    private let ollama = OllamaClient()
    private let keynote = KeynoteBridge()
    private var inFlight: Task<Void, Never>?

    func clearChat() {
        messages.removeAll()
        lastError = nil
        statusText = "Ready"
    }

    func cancel() {
        inFlight?.cancel()
        inFlight = nil
        isBusy = false
        statusText = "Cancelled"
    }

    func refreshDigestPreview() async -> String {
        do {
            statusText = "Reading Keynote…"
            let digest = try await keynote.presentationDigest()
            statusText = "Ready"
            return digest
        } catch {
            statusText = "Ready"
            return "Error: \(error.localizedDescription)"
        }
    }

    func send(userText: String, settings: AppSettings) {
        let trimmed = userText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, !isBusy else { return }

        messages.append(ChatMessage(role: .user, content: trimmed))
        isBusy = true
        lastError = nil
        statusText = "Reading Keynote…"

        inFlight = Task {
            defer {
                isBusy = false
                inFlight = nil
            }
            do {
                let digest = try await keynote.presentationDigest()
                try Task.checkCancellation()
                statusText = "Calling Ollama…"
                let system = PromptLoader.buildSystemPrompt()
                let user = PromptLoader.buildUserMessage(digest: digest, userPrompt: trimmed)
                let reply = try await ollama.chatCompletion(
                    baseURL: settings.ollamaBaseURL,
                    model: settings.ollamaModel,
                    system: system,
                    user: user,
                    numCtx: settings.numCtx
                )
                try Task.checkCancellation()

                let (kept, rejected) = ActionParser.extractActionsDetailed(from: reply)
                if kept.isEmpty {
                    var content = reply.trimmingCharacters(in: .whitespacesAndNewlines)
                    if !rejected.isEmpty {
                        content = (content.isEmpty ? "" : content + "\n\n")
                            + "Blocked \(rejected.count) unsafe action(s):\n"
                            + rejected.map { "• \($0)" }.joined(separator: "\n")
                    }
                    messages.append(ChatMessage(role: .assistant, content: content))
                    statusText = "Ready"
                    return
                }

                statusText = "Applying \(kept.count) action(s)…"
                var lastSlide: Int?
                var lines: [String] = []
                var notes: [String] = []
                for action in kept {
                    try Task.checkCancellation()
                    do {
                        let (result, updatedHint) = try await keynote.apply(action, lastSlideHint: lastSlide)
                        lastSlide = updatedHint
                        if action.op == "note", let text = action.text, !text.isEmpty {
                            notes.append(text)
                        }
                        let mark = result.success ? "✓" : "✗"
                        lines.append("\(mark) \(result.op): \(result.detail)")
                    } catch {
                        // Keep applying remaining actions; a failed set_title must not strand a blank slide mid-batch.
                        lines.append("✗ \(action.op): \(error.localizedDescription)")
                    }
                }
                for item in rejected {
                    lines.append("✗ \(item)")
                }

                var content = "Applied \(kept.count) action(s):\n" + lines.joined(separator: "\n")
                if !notes.isEmpty {
                    content += "\n\n" + notes.joined(separator: "\n")
                }
                if settings.showModelJSON,
                   reply.count < 4000,
                   reply.contains("{") {
                    content += "\n\n—\nModel JSON:\n" + reply.trimmingCharacters(in: .whitespacesAndNewlines)
                }
                messages.append(ChatMessage(role: .assistant, content: content))
                statusText = "Ready"
            } catch is CancellationError {
                statusText = "Cancelled"
            } catch {
                lastError = error.localizedDescription
                messages.append(ChatMessage(role: .assistant, content: "Error: \(error.localizedDescription)"))
                statusText = "Error"
            }
        }
    }
}
