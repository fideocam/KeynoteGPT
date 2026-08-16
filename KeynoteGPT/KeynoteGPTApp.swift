import SwiftUI

@main
struct KeynoteGPTApp: App {
    @StateObject private var settings = AppSettings()
    @StateObject private var agent = AgentOrchestrator()

    var body: some Scene {
        WindowGroup("KeynoteGPT", id: "main") {
            ContentView()
                .environmentObject(settings)
                .environmentObject(agent)
                .frame(minWidth: 520, minHeight: 560)
        }
        .defaultSize(width: 720, height: 780)
        .commands {
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView()
                .environmentObject(settings)
                .environmentObject(agent)
                .frame(width: 480, height: 420)
        }

        MenuBarExtra("KeynoteGPT", systemImage: "rectangle.on.rectangle.angled") {
            MenuBarMenu()
        }
    }
}

private struct MenuBarMenu: View {
    @Environment(\.openWindow) private var openWindow

    var body: some View {
        Button("Open KeynoteGPT") {
            openWindow(id: "main")
            NSApp.activate(ignoringOtherApps: true)
        }
        Divider()
        Button("Quit KeynoteGPT") {
            NSApp.terminate(nil)
        }
    }
}
