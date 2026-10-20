import Foundation

/// Um cookie no formato Netscape (o do `cookies.txt` usado por yt-dlp e spotdl).
struct CookieEntry: Hashable, Sendable {
    var domain: String
    var includeSubdomains: Bool
    var path: String
    var secure: Bool
    /// Validade em segundos desde 1970; 0 = cookie de sessão.
    var expires: Int
    var name: String
    var value: String
    var httpOnly = false

    /// Identifica o "mesmo" cookie ao mesclar importações.
    var key: String { "\(domain.lowercased())|\(path)|\(name)" }

    var expiryDate: Date? { expires > 0 ? Date(timeIntervalSince1970: TimeInterval(expires)) : nil }
    var isExpired: Bool { expiryDate.map { $0 < Date() } ?? false }

    var service: CookieService { CookieService.of(domain: domain) }
}

enum CookieParseError: LocalizedError {
    case empty
    case unrecognized

    var errorDescription: String? {
        switch self {
        case .empty: "O arquivo está vazio."
        case .unrecognized: "Não encontrei cookies nesse arquivo. Exporte no formato cookies.txt (Netscape) ou JSON."
        }
    }
}

enum CookieFile {
    /// Lê um `cookies.txt` (Netscape) ou um JSON exportado por extensões de navegador.
    static func parse(_ text: String) throws -> [CookieEntry] {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw CookieParseError.empty }
        let cookies = trimmed.hasPrefix("[") || trimmed.hasPrefix("{") ? parseJSON(trimmed) : parseNetscape(trimmed)
        guard !cookies.isEmpty else { throw CookieParseError.unrecognized }
        return cookies
    }

    static func parseNetscape(_ text: String) -> [CookieEntry] {
        text.split(whereSeparator: \.isNewline).compactMap { rawLine in
            var line = String(rawLine).trimmingCharacters(in: CharacterSet(charactersIn: "\r"))
            var httpOnly = false
            if line.hasPrefix("#HttpOnly_") {
                httpOnly = true
                line.removeFirst("#HttpOnly_".count)
            } else if line.hasPrefix("#") || line.trimmingCharacters(in: .whitespaces).isEmpty {
                return nil
            }
            let fields = line.split(separator: "\t", omittingEmptySubsequences: false).map(String.init)
            guard fields.count >= 6, !fields[0].isEmpty, !fields[5].isEmpty else { return nil }
            return CookieEntry(
                domain: fields[0],
                includeSubdomains: fields[1].uppercased() == "TRUE",
                path: fields[2].isEmpty ? "/" : fields[2],
                secure: fields[3].uppercased() == "TRUE",
                expires: Int(Double(fields[4]) ?? 0),
                name: fields[5],
                value: fields.count > 6 ? fields[6...].joined(separator: "\t") : "",
                httpOnly: httpOnly
            )
        }
    }

    /// Formato das extensões tipo "EditThisCookie"/"Cookie-Editor": lista de objetos.
    static func parseJSON(_ text: String) -> [CookieEntry] {
        struct JSONCookie: Decodable {
            let domain: String
            let name: String
            let value: String?
            let path: String?
            let secure: Bool?
            let httpOnly: Bool?
            let hostOnly: Bool?
            let expirationDate: Double?
            let expires: Double?
        }
        let data = Data(text.utf8)
        let list = (try? JSONDecoder().decode([JSONCookie].self, from: data))
            ?? (try? JSONDecoder().decode([String: [JSONCookie]].self, from: data))?["cookies"]
            ?? []
        return list.map { cookie in
            let domain = cookie.hostOnly == true || cookie.domain.hasPrefix(".") ? cookie.domain : "." + cookie.domain
            return CookieEntry(
                domain: domain,
                includeSubdomains: domain.hasPrefix("."),
                path: cookie.path ?? "/",
                secure: cookie.secure ?? false,
                expires: Int(cookie.expirationDate ?? cookie.expires ?? 0),
                name: cookie.name,
                value: cookie.value ?? "",
                httpOnly: cookie.httpOnly ?? false
            )
        }
    }

    static func serialize(_ cookies: [CookieEntry]) -> String {
        var lines = [
            "# Netscape HTTP Cookie File",
            "# Gerado pelo Sweevi. Não compartilhe: contém suas sessões de login.",
            "",
        ]
        for c in cookies {
            let domain = (c.httpOnly ? "#HttpOnly_" : "") + c.domain
            lines.append([
                domain, c.includeSubdomains ? "TRUE" : "FALSE", c.path, c.secure ? "TRUE" : "FALSE",
                String(c.expires), c.name, c.value,
            ].joined(separator: "\t"))
        }
        return lines.joined(separator: "\n") + "\n"
    }
}

/// Serviços conhecidos e quais cookies deles são o "token" de login.
enum CookieService: String, CaseIterable, Identifiable, Sendable {
    case youtube, spotify, instagram, x, tiktok, facebook, vimeo, twitch, reddit, soundcloud, other

    var id: String { rawValue }

    var title: String {
        switch self {
        case .youtube: "YouTube / Google"
        case .spotify: "Spotify"
        case .instagram: "Instagram"
        case .x: "X (Twitter)"
        case .tiktok: "TikTok"
        case .facebook: "Facebook"
        case .vimeo: "Vimeo"
        case .twitch: "Twitch"
        case .reddit: "Reddit"
        case .soundcloud: "SoundCloud"
        case .other: "Outros sites"
        }
    }

    var domains: [String] {
        switch self {
        case .youtube: ["youtube.com", "google.com", "youtu.be"]
        case .spotify: ["spotify.com"]
        case .instagram: ["instagram.com"]
        case .x: ["x.com", "twitter.com"]
        case .tiktok: ["tiktok.com"]
        case .facebook: ["facebook.com"]
        case .vimeo: ["vimeo.com"]
        case .twitch: ["twitch.tv"]
        case .reddit: ["reddit.com"]
        case .soundcloud: ["soundcloud.com"]
        case .other: []
        }
    }

    /// Cookies que indicam uma sessão de login.
    var tokenNames: [String] {
        switch self {
        case .youtube: ["SAPISID", "__Secure-3PSID", "__Secure-3PAPISID", "LOGIN_INFO", "SID"]
        case .spotify: ["sp_dc", "sp_key"]
        case .instagram: ["sessionid", "ds_user_id", "csrftoken"]
        case .x: ["auth_token", "ct0"]
        case .tiktok: ["sessionid", "sid_tt", "sessionid_ss"]
        case .facebook: ["c_user", "xs"]
        case .vimeo: ["vimeo"]
        case .twitch: ["auth-token"]
        case .reddit: ["reddit_session", "token_v2"]
        case .soundcloud: ["oauth_token"]
        case .other: []
        }
    }

    /// Domínio usado ao adicionar um token manualmente.
    var primaryDomain: String { "." + (domains.first ?? "") }

    static func of(domain: String) -> CookieService {
        let host = domain.lowercased().trimmingCharacters(in: CharacterSet(charactersIn: "."))
        return allCases.first { service in
            service.domains.contains { host == $0 || host.hasSuffix("." + $0) }
        } ?? .other
    }
}

/// Resumo por serviço do que foi importado.
struct ServiceSummary: Identifiable {
    let service: CookieService
    let cookieCount: Int
    let tokens: [CookieEntry]

    var id: CookieService { service }
    var isLoggedIn: Bool { tokens.contains { !$0.isExpired && !$0.value.isEmpty } }
    var allTokensExpired: Bool { !tokens.isEmpty && tokens.allSatisfy(\.isExpired) }
    /// Validade mais próxima entre os tokens de login.
    var earliestExpiry: Date? { tokens.compactMap(\.expiryDate).min() }

    static func summarize(_ cookies: [CookieEntry]) -> [ServiceSummary] {
        let grouped = Dictionary(grouping: cookies, by: \.service)
        return CookieService.allCases.compactMap { service in
            guard let list = grouped[service], !list.isEmpty else { return nil }
            let tokens = list.filter { service.tokenNames.contains($0.name) }
            return ServiceSummary(service: service, cookieCount: list.count, tokens: tokens)
        }
    }
}
