import SwiftUI

struct ContentView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var agent: AgentOrchestrator
    @State private var draft = ""
    @State private var showingDigest = false
    @State private var digestText = ""
    @State private var showingSettings = false

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            chat
            Divider()
            composer
        }
        .background(Color(nsColor: .windowBackgroundColor))
        .sheet(isPresented: $showingDigest) {
            DigestSheet(text: digestText)
        }
        .sheet(isPresented: $showingSettings) {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(agent)
                .frame(width: 440, height: 360)
        }
    }

    private var header: some View {
        HStack(spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text("KeynoteGPT")
                    .font(.title3.weight(.semibold))
                Text(agent.statusText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Digest") {
                Task {
                    digestText = await agent.refreshDigestPreview()
                    showingDigest = true
                }
            }
            .disabled(agent.isBusy)
            Button("Settings") { showingSettings = true }
            if agent.isBusy {
                Button("Stop") { agent.cancel() }
                    .keyboardShortcut(".", modifiers: .command)
            }
            Button("Clear") { agent.clearChat() }
                .disabled(agent.isBusy || agent.messages.isEmpty)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
    }

    private var chat: some View {
        ScrollViewReader { proxy in
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 12) {
                    if agent.messages.isEmpty {
                        emptyState
                    }
                    ForEach(agent.messages) { message in
                        MessageBubble(message: message)
                            .id(message.id)
                    }
                }
                .padding(16)
            }
            .onChange(of: agent.messages.count) { _, _ in
                if let last = agent.messages.last {
                    withAnimation {
                        proxy.scrollTo(last.id, anchor: .bottom)
                    }
                }
            }
        }
    }

    private var emptyState: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Local Keynote companion")
                .font(.headline)
            Text("Open a Keynote document, then ask for analysis or changes. Edits go through allowlisted AppleScript/JXA actions — same digest → LLM → JSON pattern as BlenderGPT.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            Text("Examples")
                .font(.subheadline.weight(.semibold))
                .padding(.top, 4)
            Text("• Summarize the current deck\n• Add a closing slide with three takeaways\n• Rewrite the title on slide 0 to be shorter")
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(8)
    }

    private var composer: some View {
        VStack(alignment: .leading, spacing: 8) {
            if let error = agent.lastError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(alignment: .bottom, spacing: 10) {
                TextField("Ask KeynoteGPT…", text: $draft, axis: .vertical)
                    .textFieldStyle(.plain)
                    .lineLimit(1...6)
                    .padding(10)
                    .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 10))
                    .onSubmit(send)

                Button(action: send) {
                    Image(systemName: "arrow.up.circle.fill")
                        .font(.system(size: 28))
                }
                .buttonStyle(.plain)
                .disabled(agent.isBusy || draft.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                .keyboardShortcut(.return, modifiers: .command)
            }
            Text("Model: \(settings.ollamaModel)  ·  \(settings.ollamaBaseURL)")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        }
        .padding(16)
    }

    private func send() {
        let text = draft
        draft = ""
        agent.send(userText: text, settings: settings)
    }
}

struct MessageBubble: View {
    let message: ChatMessage

    private var usesMono: Bool {
        message.role == .assistant && (message.content.contains("{\"actions\"") || message.content.contains("Applied "))
    }

    var body: some View {
        HStack {
            if message.role == .user { Spacer(minLength: 40) }
            VStack(alignment: .leading, spacing: 4) {
                Text(message.role == .user ? "You" : "KeynoteGPT")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
                Text(message.content)
                    .textSelection(.enabled)
                    .font(usesMono ? .system(.body, design: .monospaced) : .body)
            }
            .padding(12)
            .background(bubbleColor, in: RoundedRectangle(cornerRadius: 12))
            if message.role != .user { Spacer(minLength: 40) }
        }
    }

    private var bubbleColor: Color {
        message.role == .user ? Color.accentColor.opacity(0.18) : Color.primary.opacity(0.06)
    }
}

struct DigestSheet: View {
    let text: String
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Presentation digest")
                    .font(.headline)
                Spacer()
                Button("Done") { dismiss() }
                    .keyboardShortcut(.cancelAction)
            }
            ScrollView {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(16)
        .frame(minWidth: 560, minHeight: 420)
    }
}
