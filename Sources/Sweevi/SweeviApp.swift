import SwiftUI

@main
struct SweeviApp: App {
    // Criado uma única vez; evita depender do macro @State (que exige o Xcode completo).
    private let app = AppState()

    init() {
        // Necessário para a janela ganhar foco quando rodado via `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate(ignoringOtherApps: true)
    }

    var body: some Scene {
        WindowGroup("Sweevi") {
            ContentView(app: app)
        }
        .commands {
            // Uma janela só: os modelos são compartilhados.
            CommandGroup(replacing: .newItem) {}
        }

        Settings {
            SettingsView(app: app)
        }
    }
}
