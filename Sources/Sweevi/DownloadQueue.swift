import AppKit
import Combine

/// O que fazer com um link da fila.
enum QueueJob: Sendable {
    case video(VideoPreset)
    case music(MusicFormat, MusicBitrate)

    var isMusic: Bool {
        if case .music = self { true } else { false }
    }
}

struct QueueItem: Identifiable {
    enum State: Equatable {
        case waiting, running, done, failed(String), cancelled
    }

    let id = UUID()
    let link: String
    let job: QueueJob
    let folder: URL
    var title: String?
    var state: State = .waiting
    var progress: Double?
    var detail = ""
    var file: URL?

    var isFinished: Bool {
        switch state {
        case .done, .failed, .cancelled: true
        case .waiting, .running: false
        }
    }
}

/// Fila de downloads (vídeo e música), executada sempre um link por vez.
@MainActor
final class DownloadQueue: ObservableObject {
    @Published private(set) var items: [QueueItem] = []
    @Published private(set) var isRunning = false
    private var task: Task<Void, Never>?
    private let credentials: CredentialStore

    init(credentials: CredentialStore) {
        self.credentials = credentials
    }

    /// Pausa entre links de música: o spotdl falha se receber muitas requisições seguidas.
    private let musicPauseNanoseconds: UInt64 = 2_000_000_000

    var doneCount: Int { items.filter { $0.state == .done }.count }
    var hasFinished: Bool { items.contains(where: \.isFinished) }

    /// Separa o texto colado em links (um por linha, ignorando linhas vazias e repetidas).
    static func links(from text: String) -> [String] {
        var seen = Set<String>()
        return text.split(whereSeparator: \.isNewline)
            .map { clean(String($0)) }
            .filter { !$0.isEmpty && seen.insert($0).inserted }
    }

    /// Desfaz as substituições automáticas do macOS ao digitar ("--" vira "—", aspas curvas)
    /// e tira espaços das pontas.
    static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "—", with: "--")
            .replacingOccurrences(of: "–", with: "-")
            .replacingOccurrences(of: "“", with: "\"")
            .replacingOccurrences(of: "”", with: "\"")
            .replacingOccurrences(of: "‘", with: "'")
            .replacingOccurrences(of: "’", with: "'")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    func add(_ links: [String], job: QueueJob, folder: URL) {
        items += links.map { QueueItem(link: $0, job: job, folder: folder) }
        start()
    }

    func cancelAll() {
        for index in items.indices where items[index].state == .waiting {
            items[index].state = .cancelled
            items[index].detail = "Cancelado"
        }
        task?.cancel()
    }

    func retry(_ id: QueueItem.ID) {
        update(id) {
            $0.state = .waiting
            $0.progress = nil
            $0.detail = ""
        }
        start()
    }

    func remove(_ id: QueueItem.ID) {
        items.removeAll { $0.id == id && $0.isFinished }
    }

    func clearFinished() {
        items.removeAll(where: \.isFinished)
    }

    func reveal(_ item: QueueItem) {
        if let file = item.file, FileManager.default.fileExists(atPath: file.path) {
            NSWorkspace.shared.activateFileViewerSelecting([file])
        } else {
            NSWorkspace.shared.open(item.folder)
        }
    }

    // MARK: - Execução

    private func start() {
        guard !isRunning else { return }
        isRunning = true
        task = Task {
            var lastWasMusic = false
            while !Task.isCancelled, let item = items.first(where: { $0.state == .waiting }) {
                if item.job.isMusic, lastWasMusic {
                    try? await Task.sleep(nanoseconds: musicPauseNanoseconds)
                    if Task.isCancelled { break }
                }
                update(item.id) {
                    $0.state = .running
                    $0.detail = "Iniciando…"
                }
                do {
                    switch item.job {
                    case .video(let preset): try await runVideo(item, preset: preset)
                    case .music(let format, let bitrate): try await runMusic(item, format: format, bitrate: bitrate)
                    }
                } catch is CancellationError {
                    update(item.id) {
                        $0.state = .cancelled
                        $0.detail = "Cancelado"
                        $0.progress = nil
                    }
                } catch {
                    update(item.id) {
                        $0.state = .failed(error.localizedDescription)
                        $0.detail = error.localizedDescription
                        $0.progress = nil
                    }
                }
                lastWasMusic = item.job.isMusic
            }
            // Um cancelamento no meio pode deixar o item atual marcado como "baixando".
            for index in items.indices where items[index].state == .running {
                items[index].state = .cancelled
                items[index].detail = "Cancelado"
            }
            isRunning = false
        }
    }

    private func runVideo(_ item: QueueItem, preset: VideoPreset) async throws {
        let (events, continuation) = AsyncStream.makeStream(of: DownloadEvent.self)
        let consumer = Task {
            for await event in events { handleVideo(event, for: item.id) }
        }
        defer { consumer.cancel() }
        do {
            let auth = credentials.session(for: .ytdlp)
            defer { credentials.finish(auth) }
            try await YTDLP.download(url: item.link, arguments: preset.arguments, folder: item.folder, extraArguments: auth.arguments) {
                continuation.yield($0)
            }
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
        continuation.finish()
        await consumer.value
        update(item.id) {
            $0.state = .done
            $0.progress = 1
            $0.detail = "Concluído"
        }
    }

    private func handleVideo(_ event: DownloadEvent, for id: QueueItem.ID) {
        update(id) { item in
            switch event {
            case .title(let title):
                item.title = title
            case let .progress(percent, speed, eta):
                item.progress = percent.map { $0 / 100 }
                var text = "Baixando"
                if Self.isKnown(speed) { text += " · \(speed)" }
                if Self.isKnown(eta) { text += " · faltam \(eta)" }
                item.detail = text
            case .postprocessing(let name):
                item.progress = nil
                item.detail = name == "Merger" ? "Juntando vídeo e áudio…" : "Processando…"
            case .finished(let path):
                item.file = URL(fileURLWithPath: path)
            }
        }
    }

    private func runMusic(_ item: QueueItem, format: MusicFormat, bitrate: MusicBitrate) async throws {
        let (events, continuation) = AsyncStream.makeStream(of: MusicEvent.self)
        let tally = MusicTally()
        let consumer = Task {
            for await event in events { handleMusic(event, for: item.id, tally: tally) }
        }
        do {
            let auth = credentials.session(for: .spotdl)
            defer { credentials.finish(auth) }
            try await SpotDL.download(
                query: item.link, format: format, bitrate: bitrate, folder: item.folder, extraArguments: auth.arguments
            ) {
                continuation.yield($0)
            }
        } catch {
            continuation.finish()
            await consumer.value
            throw error
        }
        continuation.finish()
        await consumer.value

        if tally.downloaded == 0, tally.skipped == 0 {
            throw ToolError.failed(tally.problems.last ?? "Nenhuma música foi baixada.")
        }
        var summary = tally.downloaded == 1 ? "1 música baixada" : "\(tally.downloaded) músicas baixadas"
        if tally.skipped > 0 { summary += " · \(tally.skipped) já existia\(tally.skipped == 1 ? "" : "m")" }
        if !tally.problems.isEmpty { summary += " · \(tally.problems.count) com erro" }
        update(item.id) {
            $0.state = .done
            $0.progress = 1
            $0.detail = summary
        }
    }

    private func handleMusic(_ event: MusicEvent, for id: QueueItem.ID, tally: MusicTally) {
        update(id) { item in
            switch event {
            case let .stage(song, stage):
                if item.title == nil { item.title = song }
                item.detail = "\(song) · \(Self.translate(stage))"
                item.progress = (Double(tally.done) + Self.stageFraction(stage)) / Double(max(tally.total, 1))
            case let .progress(done, total):
                tally.done = done
                tally.total = total
                item.progress = total > 0 ? Double(done) / Double(total) : nil
                if total > 1 { item.title = "\(total) músicas" }
            case .downloaded(let song):
                tally.downloaded += 1
                item.file = Self.findFile(named: song, in: item.folder)
            case .skipped(let song):
                tally.skipped += 1
                item.file = Self.findFile(named: song, in: item.folder)
            case .problem(let message):
                tally.problems.append(message)
            }
        }
    }

    private func update(_ id: QueueItem.ID, _ change: (inout QueueItem) -> Void) {
        guard let index = items.firstIndex(where: { $0.id == id }) else { return }
        change(&items[index])
    }

    private static func isKnown(_ value: String) -> Bool {
        !value.isEmpty && value != "NA" && !value.contains("Unknown")
    }

    /// Quanto da música atual já foi feito em cada etapa do spotdl.
    private static func stageFraction(_ stage: String) -> Double {
        switch stage {
        case "Searching for song": 0.1
        case "Getting audio meta": 0.25
        case "Downloading": 0.5
        case "Converting": 0.75
        case "Embedding metadata": 0.9
        case "Done", "Skipped": 1
        default: 0
        }
    }

    private static func translate(_ stage: String) -> String {
        switch stage {
        case "Searching for song": "procurando"
        case "Getting audio meta": "lendo informações"
        case "Downloading": "baixando"
        case "Converting": "convertendo"
        case "Embedding metadata": "gravando capa e dados"
        case "Done": "pronto"
        case "Skipped": "já existia"
        default: stage
        }
    }

    /// O spotdl não informa o caminho final; procuramos o arquivo "Artista - Música.*" na pasta.
    private static func findFile(named song: String, in folder: URL) -> URL? {
        let files = (try? FileManager.default.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? []
        return files.first { $0.deletingPathExtension().lastPathComponent == song }
    }
}

/// Contagem das músicas de um link durante o download.
@MainActor
private final class MusicTally {
    var done = 0
    var total = 1
    var downloaded = 0
    var skipped = 0
    var problems: [String] = []
}
