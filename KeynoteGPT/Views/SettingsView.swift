import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var agent: AgentOrchestrator
    @Environment(\.dismiss) private var dismiss

    /// When true (sheet presentation), show a standard Done button.
    var showsDismissButton: Bool = false

    @State private var models: [OllamaModelInfo] = []
    @State private var modelsError: String?
    @State private var keynoteTestMessage: String?
    @State private var keynoteTestSucceeded = false
    @State private var isLoadingModels = false
    @State private var isTestingKeynote = false

    var body: some View {
        NavigationStack {
            Form {
                Section("Ollama") {
                    TextField("Base URL", text: $settings.ollamaBaseURL)
                    TextField("Model", text: $settings.ollamaModel)
                    HStack {
                        Button(isLoadingModels ? "Loading…" : "Refresh models") {
                            Task { await refreshModels() }
                        }
                        .disabled(isLoadingModels)
                        if !models.isEmpty {
                            Picker("Installed", selection: $settings.ollamaModel) {
                                ForEach(models) { model in
                                    Text(model.name).tag(model.name)
                                }
                            }
                            .labelsHidden()
                        }
                    }
                    if let modelsError {
                        Text(modelsError)
                            .font(.caption)
                            .foregroundStyle(.red)
                    }
                    TextField("num_ctx (0 = server default)", value: $settings.numCtx, format: .number)
                }

                Section("Chat") {
                    Toggle("Show model JSON in replies", isOn: $settings.showModelJSON)
                    Text("When on, assistant messages include the raw Ollama JSON used to drive Keynote. Off by default.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Section("Keynote") {
                    Text("KeynoteGPT controls the frontmost Keynote document through JavaScript for Automation. Grant Automation access when macOS asks (KeynoteGPT → Keynote).")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Button(isTestingKeynote ? "Testing…" : "Test Keynote digest") {
                        Task { await testKeynoteDigest() }
                    }
                    .disabled(isTestingKeynote)
                    if let keynoteTestMessage {
                        Text(keynoteTestMessage)
                            .font(.caption)
                            .foregroundColor(keynoteTestSucceeded ? Color.secondary : Color.red)
                            .textSelection(.enabled)
                    }
                }
            }
            .formStyle(.grouped)
            .padding()
            .navigationTitle("Settings")
            .toolbar {
                if showsDismissButton {
                    ToolbarItem(placement: .confirmationAction) {
                        Button("Done") { dismiss() }
                            .keyboardShortcut(.defaultAction)
                    }
                }
            }
        }
        .task { await refreshModels() }
    }

    private func testKeynoteDigest() async {
        isTestingKeynote = true
        defer { isTestingKeynote = false }
        let digest = await agent.refreshDigestPreview()
        if digest.hasPrefix("Error:") {
            keynoteTestSucceeded = false
            keynoteTestMessage = digest
        } else if let data = digest.data(using: .utf8),
                  let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let error = obj["error"] as? String {
            keynoteTestSucceeded = false
            keynoteTestMessage = "Keynote: \(error)"
        } else {
            keynoteTestSucceeded = true
            keynoteTestMessage = "Digest OK (\(digest.count) characters). Use Digest in the main window to inspect the full snapshot."
        }
    }

    private func refreshModels() async {
        isLoadingModels = true
        defer { isLoadingModels = false }
        do {
            let client = OllamaClient()
            models = try await client.listModels(baseURL: settings.ollamaBaseURL)
            modelsError = nil
            if models.contains(where: { $0.name == settings.ollamaModel }) == false,
               let first = models.first {
                settings.ollamaModel = first.name
            }
        } catch {
            models = []
            modelsError = error.localizedDescription
        }
    }
}
