import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var agent: AgentOrchestrator
    @Environment(\.dismiss) private var dismiss

    /// When true (sheet presentation), show a standard Done button.
    var showsDismissButton: Bool = false

    @State private var models: [OllamaModelInfo] = []
    @State private var modelsError: String?
    @State private var isLoadingModels = false

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
                    Button("Test Keynote digest") {
                        Task {
                            let digest = await agent.refreshDigestPreview()
                            modelsError = digest.hasPrefix("Error:") ? digest : nil
                            if modelsError == nil {
                                modelsError = "Digest OK (\(digest.count) chars). Open Digest from the main window to inspect."
                            }
                        }
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
