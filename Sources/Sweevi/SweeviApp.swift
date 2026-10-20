import SwiftUI

@main
struct SweeviApp: App {
    init() {
        // Necessário para a janela ganhar foco quando rodado via `swift run`.
        NSApplication.shared.setActivationPolicy(.regular)
        NSApplication.shared.activate()
    }

    var body: some Scene {
        Window("Sweevi", id: "main") {
            ContentView()
        }
        .windowResizability(.contentMinSize)
    }
}
