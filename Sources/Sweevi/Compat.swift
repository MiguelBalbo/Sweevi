import SwiftUI
import UniformTypeIdentifiers

/// Ajustes para manter o visual atual no macOS 13+ e continuar funcionando no macOS 12.
extension View {
    /// Esconde o fundo padrão do TextEditor (só existe a partir do macOS 13; no 12 ele já fica branco).
    @ViewBuilder func hiddenScrollBackground() -> some View {
        if #available(macOS 13, *) {
            scrollContentBackground(.hidden)
        } else {
            self
        }
    }

    /// Formulário agrupado no macOS 13+; no 12, que não tem esse estilo nem rolagem em Form, usa uma ScrollView.
    @ViewBuilder func groupedFormStyle() -> some View {
        if #available(macOS 13, *) {
            formStyle(.grouped)
        } else {
            ScrollView {
                self.padding(20)
            }
        }
    }

    /// Aceita arquivos arrastados do Finder (equivalente ao `dropDestination(for: URL.self)` do macOS 13).
    func onFileDrop(_ handle: @escaping @MainActor (URL) -> Void) -> some View {
        onDrop(of: [UTType.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    Task { @MainActor in handle(url) }
                }
            }
            return !providers.isEmpty
        }
    }
}
