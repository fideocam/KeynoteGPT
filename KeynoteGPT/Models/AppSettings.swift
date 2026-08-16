import Foundation
import SwiftUI

@MainActor
final class AppSettings: ObservableObject {
    @AppStorage("ollamaBaseURL") var ollamaBaseURL: String = "http://127.0.0.1:11434"
    @AppStorage("ollamaModel") var ollamaModel: String = "llama3.2"
    @AppStorage("numCtx") var numCtx: Int = 0
    @AppStorage("showMenuBarExtra") var showMenuBarExtra: Bool = true
    @AppStorage("showModelJSON") var showModelJSON: Bool = false
}
