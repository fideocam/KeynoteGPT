import SwiftUI

struct SettingsView: View {
    @EnvironmentObject private var settings: AppSettings
    @EnvironmentObject private var agent: AgentOrchestrator
    @State private var models: [OllamaModelInfo] = []
    @State private var modelsError: String?
    @State private var isLoadingModels = false

    var body: some View {
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
