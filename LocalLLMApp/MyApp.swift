import SwiftUI
import SwiftData

@main
struct LocalLLMAppApp: App {      // ← keep the name already in your file
    @State private var vaultStore = VaultStore()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(vaultStore)
        }
        .modelContainer(for: Conversation.self)

        Settings {
            SettingsView()
                .environment(vaultStore)
        }
    }
}
