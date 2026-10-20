import AppKit
import Combine

/// Ferramentas externas de que o Sweevi depende.
enum Tool: String, CaseIterable, Identifiable, Codable, Sendable {
    case ytdlp = "yt-dlp"
    case ffmpeg
    case spotdl

    var id: String { rawValue }
    var name: String { rawValue }

    var purpose: String {
        switch self {
        case .ytdlp: "baixa os vídeos"
        case .ffmpeg: "junta vídeo e áudio e converte formatos"
        case .spotdl: "baixa músicas do Spotify"
        }
    }

    /// yt-dlp e ffmpeg vêm do Homebrew; o spotdl não tem fórmula e vem do pipx.
    var brewFormula: String? { self == .spotdl ? nil : rawValue }

    fileprivate var versionArguments: [String] { self == .ffmpeg ? ["-version"] : ["--version"] }
}

struct ToolStatus: Sendable {
    var path: String?
    var version: String?
    /// Instalado pelo Homebrew (o executável aponta para o Cellar).
    var isFromBrew = false
    /// Instalado pelo pipx (`~/.local/bin`).
    var isFromPipx = false

    var isInstalled: Bool { path != nil }
}

struct ToolUpdate: Identifiable, Codable, Sendable {
    let tool: Tool
    let current: String
    let latest: String
    var id: Tool { tool }
}

/// Detecta, instala e atualiza yt-dlp, ffmpeg e spotdl, mostrando o console da operação.
@MainActor
final class DependencyManager: ObservableObject {
    @Published private(set) var statuses: [Tool: ToolStatus] = [:]
    @Published private(set) var brewPath: String?
    @Published private(set) var hasLoaded = false

    @Published private(set) var updates: [ToolUpdate] = []
    @Published private(set) var isCheckingUpdates = false
    @Published private(set) var updateCheckMessage: String?

    // Operação em andamento (instalar/atualizar), exibida com barra e console.
    @Published private(set) var isWorking = false
    @Published private(set) var taskTitle = ""
    @Published private(set) var progress: Double?
    @Published private(set) var log: [String] = []
    @Published private(set) var taskError: String?
    @Published private(set) var taskFinished = false
    @Published var showConsole = false

    private static let lastCheckKey = "lastUpdateCheck"
    private static let updatesKey = "pendingUpdates"

    func status(_ tool: Tool) -> ToolStatus { statuses[tool] ?? ToolStatus() }

    func missing(_ tools: [Tool]) -> [Tool] {
        tools.filter { !status($0).isInstalled }
    }

    // MARK: - Detecção

    func refresh() async {
        brewPath = ToolRunner.find("brew")
        var result: [Tool: ToolStatus] = [:]
        for tool in Tool.allCases {
            result[tool] = await Self.detect(tool)
        }
        statuses = result
        hasLoaded = true
        restoreCachedUpdates()
    }

    /// Reaproveita o resultado da última verificação, descartando o que já foi atualizado por fora.
    private func restoreCachedUpdates() {
        guard updates.isEmpty,
              let data = UserDefaults.standard.data(forKey: Self.updatesKey),
              let cached = try? JSONDecoder().decode([ToolUpdate].self, from: data) else { return }
        updates = cached.filter { update in
            guard let version = status(update.tool).version else { return false }
            return Self.isNewer(update.latest, than: version)
        }
    }

    private func saveUpdates() {
        if let data = try? JSONEncoder().encode(updates) {
            UserDefaults.standard.set(data, forKey: Self.updatesKey)
        }
    }

    private nonisolated static func detect(_ tool: Tool) async -> ToolStatus {
        guard let path = ToolRunner.find(tool.name) else { return ToolStatus() }
        let resolved = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        var status = ToolStatus(
            path: path,
            isFromBrew: resolved.contains("/Cellar/"),
            isFromPipx: resolved.contains("/.local/pipx/") || path.hasPrefix(NSHomeDirectory() + "/.local/bin")
        )
        if let output = try? await ToolRunner.run(path, tool.versionArguments) {
            let firstLine = output.stdoutText.split(whereSeparator: \.isNewline).first.map(String.init) ?? ""
            if tool == .ffmpeg {
                // "ffmpeg version 8.0.1 Copyright ..."
                let words = firstLine.split(separator: " ")
                status.version = words.count > 2 ? String(words[2]) : nil
            } else {
                status.version = firstLine.trimmingCharacters(in: .whitespaces)
            }
        }
        return status
    }

    // MARK: - Instalação

    /// Instala as ferramentas que faltam: yt-dlp/ffmpeg (e pipx) pelo Homebrew, spotdl pelo pipx.
    func install(_ tools: [Tool]) {
        let missing = missing(tools)
        guard !missing.isEmpty, !isWorking, let brew = brewPath else { return }

        var formulas = missing.compactMap(\.brewFormula)
        let needsSpotdl = missing.contains(.spotdl)
        if needsSpotdl, ToolRunner.find("pipx") == nil { formulas.append("pipx") }

        perform(title: "Instalando \(missing.map(\.name).joined(separator: ", "))…") { manager in
            var total = needsSpotdl ? 1 : 0
            var done = 0
            if !formulas.isEmpty {
                manager.append("$ brew install \(formulas.joined(separator: " "))")
                total += await Self.plannedBrewSteps(brew: brew, verb: "install", formulas: formulas)
                manager.setProgress(done: done, total: total)
                try await manager.runLogged(brew, ["install"] + formulas) { line in
                    if line.hasPrefix("==> Pouring") {
                        done += 1
                        manager.setProgress(done: done, total: total)
                    }
                }
                done = max(done, total - (needsSpotdl ? 1 : 0))
                manager.setProgress(done: done, total: total)
            }
            if needsSpotdl {
                guard let pipx = ToolRunner.find("pipx") else { throw ToolError.notInstalled("pipx") }
                manager.append("$ pipx install spotdl")
                try await manager.runLogged(pipx, ["install", "spotdl"])
                done += 1
                manager.setProgress(done: done, total: total)
            }
        }
    }

    /// O Homebrew pede a senha de administrador, então abrimos o instalador oficial no Terminal.
    func installHomebrewInTerminal() {
        let command = #"/bin/bash -c \"$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)\""#
        let script = """
        tell application "Terminal"
            activate
            do script "\(command)"
        end tell
        """
        var error: NSDictionary?
        NSAppleScript(source: script)?.executeAndReturnError(&error)
        if let error {
            taskError = "Não foi possível abrir o Terminal: \(error[NSAppleScript.errorMessage] ?? error)"
        }
    }

    // MARK: - Atualizações

    /// Verifica novas versões. Sem `force`, só roda se a última verificação tiver mais de um dia.
    func checkForUpdates(force: Bool = false) async {
        if !force, let last = UserDefaults.standard.object(forKey: Self.lastCheckKey) as? Date,
           Date().timeIntervalSince(last) < 24 * 60 * 60 {
            return
        }
        guard !isCheckingUpdates else { return }
        isCheckingUpdates = true
        updateCheckMessage = nil
        defer { isCheckingUpdates = false }

        var found: [ToolUpdate] = []
        var problems: [String] = []

        let brewTools = Tool.allCases.filter { $0.brewFormula != nil && status($0).isFromBrew }
        if let brew = brewPath, !brewTools.isEmpty {
            do {
                found += try await Self.brewOutdated(brew: brew, tools: brewTools)
            } catch {
                problems.append("Homebrew: \(error.localizedDescription)")
            }
        }

        let spotdl = status(.spotdl)
        if let current = spotdl.version, spotdl.isFromPipx {
            do {
                let latest = try await Self.latestSpotdlVersion()
                if Self.isNewer(latest, than: current) {
                    found.append(ToolUpdate(tool: .spotdl, current: current, latest: latest))
                }
            } catch {
                problems.append("spotdl: \(error.localizedDescription)")
            }
        }

        updates = found
        saveUpdates()
        UserDefaults.standard.set(Date(), forKey: Self.lastCheckKey)
        if !problems.isEmpty {
            updateCheckMessage = "Não foi possível verificar tudo. " + problems.joined(separator: " · ")
        } else if found.isEmpty {
            updateCheckMessage = "Tudo atualizado."
        }
    }

    func upgradeAll() {
        guard !updates.isEmpty, !isWorking else { return }
        let pending = updates
        let formulas = pending.compactMap(\.tool.brewFormula)
        let upgradeSpotdl = pending.contains { $0.tool == .spotdl }
        let brew = brewPath

        perform(title: "Atualizando \(pending.map(\.tool.name).joined(separator: ", "))…") { manager in
            var total = upgradeSpotdl ? 1 : 0
            var done = 0
            if !formulas.isEmpty, let brew {
                manager.append("$ brew upgrade \(formulas.joined(separator: " "))")
                total += await Self.plannedBrewSteps(brew: brew, verb: "upgrade", formulas: formulas)
                manager.setProgress(done: done, total: total)
                try await manager.runLogged(brew, ["upgrade"] + formulas) { line in
                    if line.hasPrefix("==> Pouring") {
                        done += 1
                        manager.setProgress(done: done, total: total)
                    }
                }
                done = max(done, total - (upgradeSpotdl ? 1 : 0))
                manager.setProgress(done: done, total: total)
            }
            if upgradeSpotdl, let pipx = ToolRunner.find("pipx") {
                manager.append("$ pipx upgrade spotdl")
                try await manager.runLogged(pipx, ["upgrade", "spotdl"])
                done += 1
                manager.setProgress(done: done, total: total)
            }
            manager.updates = []
            manager.saveUpdates()
            manager.updateCheckMessage = "Tudo atualizado."
        }
    }

    func dismissTask() {
        guard !isWorking else { return }
        taskTitle = ""
        progress = nil
        log = []
        taskError = nil
        taskFinished = false
    }

    // MARK: - Execução com console

    private func perform(title: String, _ work: @escaping @MainActor (DependencyManager) async throws -> Void) {
        isWorking = true
        taskFinished = false
        taskTitle = title
        taskError = nil
        progress = nil
        log = []
        Task {
            do {
                try await work(self)
                taskTitle = "Concluído"
                progress = 1
            } catch {
                taskError = error.localizedDescription
                taskTitle = "Falhou"
                append("✗ \(error.localizedDescription)")
            }
            await refresh()
            isWorking = false
            taskFinished = true
        }
    }

    private func append(_ line: String) {
        log.append(line)
        if log.count > 2000 { log.removeFirst(log.count - 2000) }
    }

    private func setProgress(done: Int, total: Int) {
        progress = total > 0 ? min(Double(done) / Double(total), 1) : nil
    }

    /// Roda um comando enviando cada linha ao console (e a `onLine`, já na main actor).
    private func runLogged(
        _ executable: String,
        _ arguments: [String],
        onLine: (@MainActor (String) -> Void)? = nil
    ) async throws {
        let (lines, continuation) = AsyncStream.makeStream(of: String.self)
        let consumer = Task { @MainActor in
            for await line in lines {
                append(line)
                onLine?(line)
            }
        }
        let output: ToolRunner.Output
        do {
            output = try await ToolRunner.run(executable, arguments) { continuation.yield($0) }
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
        continuation.finish()
        await consumer.value
        guard output.status == 0 else {
            let name = URL(fileURLWithPath: executable).lastPathComponent
            throw ToolError.failed(ToolRunner.errorMessage(
                from: output.stderr + "\n" + output.stdoutText,
                fallback: "\(name) terminou com erro (código \(output.status))."
            ))
        }
    }

    // MARK: - Consultas

    /// Quantas fórmulas o brew vai instalar/atualizar (soma das linhas "Would install/upgrade N").
    private nonisolated static func plannedBrewSteps(brew: String, verb: String, formulas: [String]) async -> Int {
        guard let output = try? await ToolRunner.run(brew, [verb, "--dry-run"] + formulas) else {
            return formulas.count
        }
        let text = output.stdoutText + "\n" + output.stderr
        let total = text.allCaptures(#"==> Would (?:install|upgrade) (\d+)"#).compactMap { Int($0[0]) }.reduce(0, +)
        return max(total, formulas.count)
    }

    private nonisolated static func brewOutdated(brew: String, tools: [Tool]) async throws -> [ToolUpdate] {
        _ = try? await ToolRunner.run(brew, ["update", "--quiet"])
        let output = try await ToolRunner.run(brew, ["outdated", "--json=v2"] + tools.compactMap(\.brewFormula))
        struct Response: Decodable {
            struct Formula: Decodable {
                let name: String
                let installed_versions: [String]
                let current_version: String
            }
            let formulae: [Formula]
        }
        guard let response = try? JSONDecoder().decode(Response.self, from: output.stdout) else {
            throw ToolError.failed(ToolRunner.errorMessage(from: output.stderr, fallback: "resposta inválida do brew"))
        }
        return response.formulae.compactMap { formula in
            guard let tool = Tool(rawValue: formula.name) else { return nil }
            return ToolUpdate(tool: tool, current: formula.installed_versions.last ?? "?", latest: formula.current_version)
        }
    }

    private nonisolated static func latestSpotdlVersion() async throws -> String {
        struct PyPI: Decodable {
            struct Info: Decodable { let version: String }
            let info: Info
        }
        let (data, _) = try await URLSession.shared.data(from: URL(string: "https://pypi.org/pypi/spotdl/json")!)
        return try JSONDecoder().decode(PyPI.self, from: data).info.version
    }

    nonisolated static func isNewer(_ a: String, than b: String) -> Bool {
        let parse = { (s: String) in s.split(whereSeparator: { !$0.isNumber }).compactMap { Int($0) } }
        let x = parse(a), y = parse(b)
        for i in 0..<max(x.count, y.count) {
            let l = i < x.count ? x[i] : 0, r = i < y.count ? y[i] : 0
            if l != r { return l > r }
        }
        return false
    }
}
