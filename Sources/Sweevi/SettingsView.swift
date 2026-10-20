import SwiftUI

enum SettingsTab: Hashable {
    case cookies, dependencies
}

/// Botão que abre a janela de Configurações em qualquer versão do macOS.
struct OpenSettingsButton: View {
    var before: () -> Void = {}

    var body: some View {
        if #available(macOS 14, *) {
            ModernOpenSettingsButton(before: before)
        } else {
            Button {
                before()
                // macOS 13 usa "showSettingsWindow:"; o 12, "showPreferencesWindow:".
                let selector = if #available(macOS 13, *) { "showSettingsWindow:" } else { "showPreferencesWindow:" }
                NSApp.sendAction(Selector((selector)), to: nil, from: nil)
            } label: {
                Label("Configurações", systemImage: "gearshape")
            }
        }
    }
}

@available(macOS 14, *)
private struct ModernOpenSettingsButton: View {
    let before: () -> Void
    @Environment(\.openSettings) private var openSettings

    var body: some View {
        Button {
            before()
            openSettings()
        } label: {
            Label("Configurações", systemImage: "gearshape")
        }
    }
}

/// Janela de Configurações (⌘,).
struct SettingsView: View {
    @ObservedObject var app: AppState

    var body: some View {
        TabView(selection: $app.settingsTab) {
            CookiesPane(store: app.credentials)
                .tabItem { Label("Cookies e tokens", systemImage: "key.fill") }
                .tag(SettingsTab.cookies)
            DependenciesPane(app: app)
                .tabItem { Label("Dependências", systemImage: "shippingbox") }
                .tag(SettingsTab.dependencies)
        }
        .frame(width: 580, height: 640)
        .tint(.sweevi)
    }
}

/// Cookies (cookies.txt) para yt-dlp e spotdl, tokens manuais e credenciais do Spotify.
struct CookiesPane: View {
    @ObservedObject var store: CredentialStore

    var body: some View {
        Form {
            importSection
            if !store.cookies.isEmpty { servicesSection }
            manualTokenSection
            spotifySection
            storageSection
        }
        .groupedFormStyle()
        .confirmationDialog("Apagar todos os cookies e tokens?", isPresented: $store.confirmForget) {
            Button("Apagar tudo", role: .destructive, action: store.forgetEverything)
        } message: {
            Text("Os downloads que precisam de login vão parar de funcionar até você importar de novo.")
        }
    }

    // MARK: Seções

    private var importSection: some View {
        Section {
            VStack(spacing: 8) {
                Image(systemName: "doc.badge.plus")
                    .font(.largeTitle)
                    .foregroundStyle(Color.sweevi)
                Text("Arraste o cookies.txt aqui")
                    .font(.headline)
                Text("Formato Netscape (cookies.txt) ou JSON exportado do navegador.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Button("Escolher arquivo…", action: store.chooseCookieFile)
            }
            .frame(maxWidth: .infinity)
            .padding(.vertical, 10)
            .contentShape(Rectangle())
            .onFileDrop { store.importCookies(from: $0) }

            if let message = store.importMessage {
                Label(message, systemImage: store.importFailed ? "exclamationmark.triangle.fill" : "checkmark.circle.fill")
                    .foregroundStyle(store.importFailed ? .orange : .green)
                    .font(.callout)
            }

            DisclosureGroup("Como gerar o cookies.txt") {
                VStack(alignment: .leading, spacing: 6) {
                    Text("1. Entre na sua conta do site (YouTube, Instagram…) no navegador.")
                    Text("2. Exporte os cookies com uma extensão como “Get cookies.txt LOCALLY” (Chrome/Edge) ou “cookies.txt” (Firefox).")
                    Text("3. Arraste o arquivo para cá. O Sweevi encontra os tokens de login de cada serviço.")
                    Text("Os cookies dão acesso à sua conta: não compartilhe o arquivo e apague-o depois de importar.")
                        .foregroundStyle(.secondary)
                }
                .font(.callout)
                .padding(.top, 4)
            }
        } header: {
            Text("Importar cookies")
        } footer: {
            Text("Com os cookies, o yt-dlp baixa vídeos que exigem login (privados, com restrição de idade, Instagram, X…) e o spotdl usa sua conta do YouTube Music.")
        }
    }

    private var servicesSection: some View {
        Section {
            ForEach(store.summaries) { summary in
                ServiceRow(summary: summary) { store.remove(summary.service) }
            }
            Toggle("Usar nos vídeos (yt-dlp)", isOn: $store.useCookiesWithYTDLP)
            Toggle("Usar nas músicas (spotdl, via YouTube Music)", isOn: $store.useCookiesWithSpotDL)
            Button("Apagar todos os cookies", role: .destructive, action: store.removeAllCookies)
        } header: {
            Text("Tokens encontrados")
        }
    }

    private var manualTokenSection: some View {
        Section {
            Picker("Serviço", selection: $store.draftService) {
                ForEach(CookieService.allCases.filter { $0 != .other }) { Text($0.title).tag($0) }
            }
            Picker("Token", selection: $store.draftName) {
                ForEach(store.draftService.tokenNames, id: \.self) { Text($0).tag($0) }
            }
            SecureField("Valor", text: $store.draftValue)
            HStack {
                Spacer()
                Button("Adicionar token", action: store.addDraftToken)
                    .disabled(store.draftValue.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Adicionar token manualmente")
        } footer: {
            Text("Para quem copiou só o valor de um cookie (por exemplo o “sessionid” do Instagram) nas ferramentas de desenvolvedor do navegador.")
        }
    }

    private var spotifySection: some View {
        Section {
            TextField("Client ID", text: $store.spotifyClientID)
            SecureField("Client Secret", text: $store.spotifyClientSecret)
            SecureField("Token de acesso (opcional)", text: $store.spotifyAuthToken)
            Link("Criar um app no Spotify for Developers",
                 destination: URL(string: "https://developer.spotify.com/dashboard")!)
                .font(.callout)
        } header: {
            Text("Spotify (spotdl)")
        } footer: {
            Text("Com seu próprio Client ID e Secret, o spotdl não depende da chave compartilhada, que costuma bater no limite de pedidos quando há muitos links. O token de acesso expira em cerca de uma hora.")
        }
    }

    private var storageSection: some View {
        Section {
            Toggle("Lembrar cookies e tokens neste Mac", isOn: $store.rememberCredentials)
            Button("Apagar tudo…", role: .destructive) { store.confirmForget = true }
        } header: {
            Text("Armazenamento")
        } footer: {
            Text(store.rememberCredentials
                 ? "Guardados nas Chaves do macOS (criptografados). Na primeira vez, o macOS pode pedir sua senha para o Sweevi acessar."
                 : "Ficam só na memória e são esquecidos quando o Sweevi fecha.")
        }
    }
}

private struct ServiceRow: View {
    let summary: ServiceSummary
    let onRemove: () -> Void

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
            VStack(alignment: .leading, spacing: 2) {
                Text(summary.service.title).bold()
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Remover", systemImage: "trash", action: onRemove)
                .labelStyle(.iconOnly)
                .buttonStyle(.borderless)
                .help("Remover os cookies de \(summary.service.title)")
        }
    }

    private var icon: String {
        if summary.isLoggedIn { return "person.crop.circle.badge.checkmark" }
        if summary.allTokensExpired { return "exclamationmark.triangle.fill" }
        return "circle.dashed"
    }

    private var color: Color {
        if summary.isLoggedIn { return .green }
        if summary.allTokensExpired { return .orange }
        return .secondary
    }

    private var detail: String {
        var parts = ["\(summary.cookieCount) cookie\(summary.cookieCount == 1 ? "" : "s")"]
        if summary.tokens.isEmpty {
            parts.append(summary.service == .other ? "sem login reconhecido" : "nenhum token de login")
        } else {
            parts.append(summary.tokens.map(\.name).joined(separator: ", "))
            if summary.allTokensExpired {
                parts.append("expirado")
            } else if let expiry = summary.earliestExpiry {
                parts.append("válido até \(expiry.formatted(date: .abbreviated, time: .omitted))")
            }
        }
        if summary.service == .spotify {
            parts.append("o spotdl usa Client ID/Secret, não estes cookies")
        }
        return parts.joined(separator: " · ")
    }
}
