import AppKit
import Observation

@Observable
@MainActor
final class DownloaderModel {
    var url = ""
    var info: VideoInfo?
    var options: [DownloadOption] = []
    var rawOptions: [DownloadOption] = []
    var selectedID: DownloadOption.ID?

    var isFetching = false
    var isDownloading = false
    var progress: Double?
    var status = ""
    var errorMessage: String?
    var downloadedFile: URL?

    var folder: URL {
        didSet { UserDefaults.standard.set(folder.path, forKey: "downloadFolder") }
    }

    let isInstalled = YTDLP.executable != nil
    private var task: Task<Void, Never>?

    init() {
        if let saved = UserDefaults.standard.string(forKey: "downloadFolder") {
            folder = URL(fileURLWithPath: saved)
        } else {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
    }

    var selectedOption: DownloadOption? {
        (options + rawOptions).first { $0.id == selectedID }
    }

    var canFetch: Bool {
        !url.trimmingCharacters(in: .whitespaces).isEmpty && !isFetching && !isDownloading
    }

    func paste() {
        if let text = NSPasteboard.general.string(forType: .string) {
            url = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func fetch() {
        guard canFetch else { return }
        let link = url.trimmingCharacters(in: .whitespaces)
        info = nil
        options = []
        rawOptions = []
        selectedID = nil
        errorMessage = nil
        downloadedFile = nil
        status = ""
        progress = nil
        isFetching = true

        task = Task {
            defer { isFetching = false }
            do {
                let info = try await YTDLP.fetchInfo(url: link)
                self.info = info
                options = DownloadOption.options(for: info)
                rawOptions = (info.formats ?? []).filter { $0.hasVideo || $0.hasAudio }.reversed().map(DownloadOption.raw)
                selectedID = options.first?.id
            } catch is CancellationError {
            } catch {
                errorMessage = error.localizedDescription
            }
        }
    }

    func download() {
        guard let option = selectedOption, !isDownloading else { return }
        let link = url.trimmingCharacters(in: .whitespaces)
        let folder = folder
        errorMessage = nil
        downloadedFile = nil
        progress = nil
        status = "Iniciando…"
        isDownloading = true

        task = Task {
            let (events, continuation) = AsyncStream.makeStream(of: DownloadEvent.self)
            let consumer = Task {
                for await event in events { handle(event) }
            }
            do {
                try await YTDLP.download(url: link, option: option, folder: folder) { continuation.yield($0) }
                continuation.finish()
                await consumer.value
                status = "Concluído"
                progress = 1
            } catch {
                continuation.finish()
                await consumer.value
                if error is CancellationError {
                    status = "Cancelado"
                } else {
                    status = ""
                    errorMessage = error.localizedDescription
                }
                progress = nil
            }
            isDownloading = false
        }
    }

    func cancel() {
        task?.cancel()
    }

    func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.directoryURL = folder
        panel.prompt = "Escolher"
        if panel.runModal() == .OK, let url = panel.url {
            folder = url
        }
    }

    func revealInFinder() {
        guard let downloadedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([downloadedFile])
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case let .progress(percent, speed, eta):
            progress = percent.map { $0 / 100 }
            var text = "Baixando"
            if isKnown(speed) { text += " · \(speed)" }
            if isKnown(eta) { text += " · faltam \(eta)" }
            status = text
        case .postprocessing(let name):
            progress = nil
            status = switch name {
            case "Merger": "Juntando vídeo e áudio…"
            case "ExtractAudio": "Convertendo áudio…"
            case "MoveFiles": "Finalizando…"
            default: "Processando (\(name))…"
            }
        case .finished(let path):
            downloadedFile = URL(fileURLWithPath: path)
        }
    }

    private func isKnown(_ value: String) -> Bool {
        !value.isEmpty && value != "NA" && !value.contains("Unknown")
    }
}
