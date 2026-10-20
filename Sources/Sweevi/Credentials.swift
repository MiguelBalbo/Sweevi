import AppKit
import Combine
import Security

/// Argumentos de autenticação para uma execução, com o arquivo temporário de cookies (se houver).
struct AuthSession: Sendable {
    let arguments: [String]
    let cookieFile: URL?

    static let none = AuthSession(arguments: [], cookieFile: nil)
}

/// Cookies e tokens usados pelo yt-dlp e pelo spotdl.
/// Ficam só na memória, ou nas Chaves do macOS se o usuário pedir para lembrar.
@MainActor
final class CredentialStore: ObservableObject {
    @Published private(set) var cookies: [CookieEntry] = [] { didSet { persist() } }

    @Published var useCookiesWithYTDLP: Bool { didSet { UserDefaults.standard.set(useCookiesWithYTDLP, forKey: "cookiesYTDLP") } }
    @Published var useCookiesWithSpotDL: Bool { didSet { UserDefaults.standard.set(useCookiesWithSpotDL, forKey: "cookiesSpotDL") } }

    @Published var spotifyClientID = "" { didSet { persist() } }
    @Published var spotifyClientSecret = "" { didSet { persist() } }
    @Published var spotifyAuthToken = "" { didSet { persist() } }

    /// Guardar nas Chaves do macOS para continuar disponível depois de fechar o app.
    @Published var rememberCredentials: Bool {
        didSet {
            UserDefaults.standard.set(rememberCredentials, forKey: "rememberCredentials")
            if rememberCredentials { persist() } else { Keychain.delete() }
        }
    }

    /// Mensagem da última importação (ou erro).
    @Published private(set) var importMessage: String?
    @Published private(set) var importFailed = false

    // Rascunho do formulário "Adicionar token manualmente".
    @Published var draftService: CookieService = .youtube { didSet { draftName = draftService.tokenNames.first ?? "" } }
    @Published var draftName = CookieService.youtube.tokenNames.first ?? ""
    @Published var draftValue = ""
    @Published var confirmForget = false

    private var isLoading = false
    private let sessionDirectory: URL

    init() {
        let defaults = UserDefaults.standard
        useCookiesWithYTDLP = defaults.object(forKey: "cookiesYTDLP") as? Bool ?? true
        useCookiesWithSpotDL = defaults.object(forKey: "cookiesSpotDL") as? Bool ?? true
        rememberCredentials = defaults.bool(forKey: "rememberCredentials")

        // Pasta privada (0700) para os cookies entregues às ferramentas; apagada ao sair.
        sessionDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("Sweevi-\(ProcessInfo.processInfo.processIdentifier)", isDirectory: true)
        try? FileManager.default.createDirectory(
            at: sessionDirectory, withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700]
        )
        let directory = sessionDirectory
        NotificationCenter.default.addObserver(
            forName: NSApplication.willTerminateNotification, object: nil, queue: nil
        ) { _ in
            try? FileManager.default.removeItem(at: directory)
        }

        if rememberCredentials { load() }
    }

    var summaries: [ServiceSummary] { ServiceSummary.summarize(cookies) }
    var hasSpotifyCredentials: Bool { !spotifyClientID.isEmpty && !spotifyClientSecret.isEmpty }

    // MARK: - Importação

    /// Lê um cookies.txt (ou JSON) e mescla com os cookies já guardados.
    func importCookies(from url: URL) {
        let accessing = url.startAccessingSecurityScopedResource()
        defer { if accessing { url.stopAccessingSecurityScopedResource() } }
        do {
            let text = try String(contentsOf: url, encoding: .utf8)
            let imported = try CookieFile.parse(text)
            merge(imported)
            let services = ServiceSummary.summarize(imported)
            let logged = services.filter(\.isLoggedIn).map(\.service.title)
            var message = "\(imported.count) cookies importados de \(services.count) serviço\(services.count == 1 ? "" : "s")."
            if !logged.isEmpty { message += " Login encontrado: \(logged.joined(separator: ", "))." }
            importMessage = message
            importFailed = false
        } catch {
            importMessage = error.localizedDescription
            importFailed = true
        }
    }

    func chooseCookieFile() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Importar"
        panel.message = "Escolha o cookies.txt exportado do navegador"
        if panel.runModal() == .OK {
            panel.urls.forEach(importCookies(from:))
        }
    }

    /// Cria o cookie de login de um serviço a partir de um token colado à mão.
    func addDraftToken() {
        let name = draftName.trimmingCharacters(in: .whitespaces)
        let value = draftValue.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty, !value.isEmpty, draftService != .other else { return }
        let oneYear = Int(Date().addingTimeInterval(365 * 24 * 60 * 60).timeIntervalSince1970)
        merge([CookieEntry(
            domain: draftService.primaryDomain, includeSubdomains: true, path: "/",
            secure: true, expires: oneYear, name: name, value: value, httpOnly: true
        )])
        importMessage = "Token \(name) adicionado para \(draftService.title)."
        importFailed = false
        draftValue = ""
    }

    func remove(_ service: CookieService) {
        cookies.removeAll { $0.service == service }
    }

    func removeAllCookies() {
        cookies = []
        importMessage = nil
    }

    func forgetEverything() {
        cookies = []
        spotifyClientID = ""
        spotifyClientSecret = ""
        spotifyAuthToken = ""
        importMessage = nil
        Keychain.delete()
    }

    private func merge(_ new: [CookieEntry]) {
        var byKey = Dictionary(cookies.map { ($0.key, $0) }, uniquingKeysWith: { _, last in last })
        var order = cookies.map(\.key)
        for cookie in new {
            if byKey[cookie.key] == nil { order.append(cookie.key) }
            byKey[cookie.key] = cookie
        }
        cookies = order.compactMap { byKey[$0] }
    }

    // MARK: - Uso pelas ferramentas

    /// Argumentos para uma execução de `tool`. Cada execução recebe a sua própria cópia dos cookies.
    func session(for tool: Tool) -> AuthSession {
        var arguments: [String] = []
        var file: URL?
        let wantsCookies = tool == .ytdlp ? useCookiesWithYTDLP : useCookiesWithSpotDL
        if wantsCookies, !cookies.isEmpty {
            file = writeCookieFile()
            if let file { arguments += [tool == .ytdlp ? "--cookies" : "--cookie-file", file.path] }
        }
        if tool == .spotdl {
            if hasSpotifyCredentials {
                arguments += ["--client-id", spotifyClientID, "--client-secret", spotifyClientSecret]
            }
            if !spotifyAuthToken.isEmpty {
                arguments += ["--auth-token", spotifyAuthToken]
            }
        }
        return AuthSession(arguments: arguments, cookieFile: file)
    }

    /// Depois da execução: o yt-dlp grava de volta os cookies renovados pelo site; guardamos e apagamos a cópia.
    func finish(_ session: AuthSession) {
        guard let file = session.cookieFile else { return }
        if let text = try? String(contentsOf: file, encoding: .utf8),
           let updated = try? CookieFile.parse(text) {
            let known = Set(cookies.map(\.key))
            let changed = updated.filter { cookie in
                known.contains(cookie.key) && cookies.first(where: { $0.key == cookie.key })?.value != cookie.value
            }
            if !changed.isEmpty { merge(changed) }
        }
        try? FileManager.default.removeItem(at: file)
    }

    private func writeCookieFile() -> URL? {
        let url = sessionDirectory.appendingPathComponent("cookies-\(UUID().uuidString).txt")
        let created = FileManager.default.createFile(
            atPath: url.path,
            contents: Data(CookieFile.serialize(cookies).utf8),
            attributes: [.posixPermissions: 0o600]
        )
        return created ? url : nil
    }

    // MARK: - Chaves do macOS

    private struct Stored: Codable {
        var cookies: String
        var spotifyClientID: String
        var spotifyClientSecret: String
        var spotifyAuthToken: String
    }

    private func persist() {
        guard rememberCredentials, !isLoading else { return }
        let stored = Stored(
            cookies: CookieFile.serialize(cookies),
            spotifyClientID: spotifyClientID,
            spotifyClientSecret: spotifyClientSecret,
            spotifyAuthToken: spotifyAuthToken
        )
        if let data = try? JSONEncoder().encode(stored) { Keychain.save(data) }
    }

    private func load() {
        guard let data = Keychain.load(), let stored = try? JSONDecoder().decode(Stored.self, from: data) else { return }
        isLoading = true
        defer { isLoading = false }
        cookies = CookieFile.parseNetscape(stored.cookies)
        spotifyClientID = stored.spotifyClientID
        spotifyClientSecret = stored.spotifyClientSecret
        spotifyAuthToken = stored.spotifyAuthToken
    }
}

/// Um único item "senha genérica" nas Chaves do macOS com todos os cookies e tokens.
private enum Keychain {
    private static let service = "local.sweevi"
    private static let account = "credentials"

    private static var query: [String: Any] {
        [
            kSecClass as String: kSecClassGenericPassword,
            kSecAttrService as String: service,
            kSecAttrAccount as String: account,
        ]
    }

    static func save(_ data: Data) {
        let update: [String: Any] = [kSecValueData as String: data]
        let status = SecItemUpdate(query as CFDictionary, update as CFDictionary)
        if status == errSecItemNotFound {
            var item = query
            item[kSecValueData as String] = data
            item[kSecAttrAccessible as String] = kSecAttrAccessibleWhenUnlocked
            item[kSecAttrLabel as String] = "Sweevi — cookies e tokens"
            SecItemAdd(item as CFDictionary, nil)
        }
    }

    static func load() -> Data? {
        var request = query
        request[kSecReturnData as String] = true
        request[kSecMatchLimit as String] = kSecMatchLimitOne
        var result: AnyObject?
        guard SecItemCopyMatching(request as CFDictionary, &result) == errSecSuccess else { return nil }
        return result as? Data
    }

    static func delete() {
        SecItemDelete(query as CFDictionary)
    }
}
