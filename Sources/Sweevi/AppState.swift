import AppKit
import Combine

/// Estado central da janela: modo, opções, pasta de destino e os modelos de cada fluxo.
@MainActor
final class AppState: ObservableObject {
    let credentials: CredentialStore
    let video: DownloaderModel
    let queue: DownloadQueue
    let dependencies = DependencyManager()

    @Published var mode: MediaMode { didSet { save(mode.rawValue, "mode") } }
    @Published var isBatch: Bool { didSet { save(isBatch, "isBatch") } }
    @Published var videoPreset: VideoPreset { didSet { save(videoPreset.rawValue, "videoPreset") } }
    @Published var musicFormat: MusicFormat { didSet { save(musicFormat.rawValue, "musicFormat") } }
    @Published var musicBitrate: MusicBitrate { didSet { save(musicBitrate.rawValue, "musicBitrate") } }
    @Published var folder: URL { didSet { save(folder.path, "downloadFolder") } }

    /// Link único do modo Música.
    @Published var musicLink = ""
    /// Links colados no modo em massa (um por linha).
    @Published var batchText = ""
    @Published var settingsTab: SettingsTab = .cookies

    /// Repassa as mudanças dos modelos filhos, para as telas que observam o AppState se atualizarem.
    private var forwarders: [AnyCancellable] = []

    init() {
        credentials = CredentialStore()
        video = DownloaderModel(credentials: credentials)
        queue = DownloadQueue(credentials: credentials)
        let defaults = UserDefaults.standard
        mode = defaults.string(forKey: "mode").flatMap(MediaMode.init) ?? .video
        isBatch = defaults.bool(forKey: "isBatch")
        videoPreset = defaults.string(forKey: "videoPreset").flatMap(VideoPreset.init) ?? .best
        musicFormat = defaults.string(forKey: "musicFormat").flatMap(MusicFormat.init) ?? .mp3
        musicBitrate = defaults.string(forKey: "musicBitrate").flatMap(MusicBitrate.init) ?? .auto
        if let saved = defaults.string(forKey: "downloadFolder") {
            folder = URL(fileURLWithPath: saved)
        } else {
            folder = FileManager.default.urls(for: .downloadsDirectory, in: .userDomainMask).first
                ?? URL(fileURLWithPath: NSHomeDirectory())
        }
        forwarders = [
            credentials.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            video.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            queue.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
            dependencies.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() },
        ]
    }

    var missingTools: [Tool] { dependencies.missing(mode.tools) }

    /// Links que o botão Baixar vai colocar na fila no modo atual.
    var pendingLinks: [String] {
        if mode == .music, !isBatch {
            let link = DownloadQueue.clean(musicLink)
            return link.isEmpty ? [] : [link]
        }
        return DownloadQueue.links(from: batchText)
    }

    func enqueue() {
        let links = pendingLinks
        guard !links.isEmpty else { return }
        let job: QueueJob = mode == .music ? .music(musicFormat, musicBitrate) : .video(videoPreset)
        queue.add(links, job: job, folder: folder)
        if mode == .music, !isBatch { musicLink = "" } else { batchText = "" }
    }

    func pasteMusicLink() {
        if let text = NSPasteboard.general.string(forType: .string) {
            musicLink = text.trimmingCharacters(in: .whitespacesAndNewlines)
        }
    }

    func pasteIntoBatch() {
        guard let text = NSPasteboard.general.string(forType: .string) else { return }
        batchText += (batchText.isEmpty || batchText.hasSuffix("\n") ? "" : "\n") + text
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

    /// Ao abrir: detecta as ferramentas e procura atualizações (no máximo uma vez por dia).
    func onLaunch() async {
        await dependencies.refresh()
        await dependencies.checkForUpdates()
    }

    private func save(_ value: Any, _ key: String) {
        UserDefaults.standard.set(value, forKey: key)
    }
}
