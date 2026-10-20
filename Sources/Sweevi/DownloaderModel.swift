import AppKit
import Combine

@MainActor
final class DownloaderModel: ObservableObject {
    @Published var url = ""
    @Published var info: VideoInfo?
    @Published var options: [DownloadOption] = []
    @Published var rawOptions: [DownloadOption] = []
    @Published var selectedID: DownloadOption.ID?

    @Published var isFetching = false
    @Published var isDownloading = false
    @Published var progress: Double?
    @Published var status = ""
    @Published var errorMessage: String?
    @Published var downloadedFile: URL?
    @Published var showAllFormats = false

    private var task: Task<Void, Never>?
    private let credentials: CredentialStore

    init(credentials: CredentialStore) {
        self.credentials = credentials
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
        let link = DownloadQueue.clean(url)
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
                let auth = credentials.session(for: .ytdlp)
                defer { credentials.finish(auth) }
                let info = try await YTDLP.fetchInfo(url: link, extraArguments: auth.arguments)
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

    func download(to folder: URL) {
        guard let option = selectedOption, !isDownloading else { return }
        let link = DownloadQueue.clean(url)
        errorMessage = nil
        downloadedFile = nil
        progress = nil
        status = "Iniciando…"
        isDownloading = true

        task = Task {
            let auth = credentials.session(for: .ytdlp)
            defer { credentials.finish(auth) }
            let (events, continuation) = AsyncStream.makeStream(of: DownloadEvent.self)
            let consumer = Task {
                for await event in events { handle(event) }
            }
            do {
                try await YTDLP.download(url: link, arguments: option.arguments, folder: folder, extraArguments: auth.arguments) {
                    continuation.yield($0)
                }
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

    func revealInFinder() {
        guard let downloadedFile else { return }
        NSWorkspace.shared.activateFileViewerSelecting([downloadedFile])
    }

    private func handle(_ event: DownloadEvent) {
        switch event {
        case .title:
            break
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
