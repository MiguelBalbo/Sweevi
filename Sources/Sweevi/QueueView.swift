import SwiftUI

/// Entrada de links para a fila: vídeo em massa, música (um link) e música em massa.
struct QueueInputView: View {
    @ObservedObject var app: AppState

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            if app.mode == .music, !app.isBatch {
                HStack {
                    TextField("Link do Spotify (faixa, álbum ou playlist) ou “Artista - Música”", text: $app.musicLink)
                        .textFieldStyle(.roundedBorder)
                        .onSubmit(app.enqueue)
                    Button("Colar", systemImage: "doc.on.clipboard", action: app.pasteMusicLink)
                        .labelStyle(.iconOnly)
                        .help("Colar link")
                }
            } else {
                batchEditor
            }

            HStack {
                if app.mode == .video {
                    Picker("Qualidade", selection: $app.videoPreset) {
                        ForEach(VideoPreset.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                } else {
                    Picker("Formato", selection: $app.musicFormat) {
                        ForEach(MusicFormat.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                    Picker("Qualidade", selection: $app.musicBitrate) {
                        ForEach(MusicBitrate.allCases) { Text($0.title).tag($0) }
                    }
                    .fixedSize()
                }
                Spacer()
                let count = app.pendingLinks.count
                Button(count > 1 ? "Baixar \(count) links" : "Baixar", systemImage: "arrow.down.circle.fill", action: app.enqueue)
                    .buttonStyle(.borderedProminent)
                    .keyboardShortcut(.defaultAction)
                    .disabled(count == 0)
            }
        }
    }

    private var batchEditor: some View {
        VStack(alignment: .leading, spacing: 4) {
            TextEditor(text: $app.batchText)
                .font(.callout.monospaced())
                .hiddenScrollBackground()
                .padding(6)
                .frame(height: 110)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(.separator))
                .overlay(alignment: .topLeading) {
                    if app.batchText.isEmpty {
                        Text(app.mode == .video
                             ? "Cole um link por linha (YouTube, Vimeo, Instagram…)"
                             : "Cole um link do Spotify por linha")
                            .foregroundStyle(.tertiary)
                            .padding(.horizontal, 11)
                            .padding(.vertical, 6)
                            .allowsHitTesting(false)
                    }
                }
            HStack {
                Text(app.mode == .video
                     ? "Os vídeos são baixados um de cada vez."
                     : "As músicas são baixadas um link de cada vez, com uma pausa entre eles.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button("Colar", systemImage: "doc.on.clipboard", action: app.pasteIntoBatch)
                    .controlSize(.small)
            }
        }
    }
}

/// Lista da fila com status por link.
struct QueueListView: View {
    @ObservedObject var queue: DownloadQueue

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack {
                Text("Fila · \(queue.doneCount) de \(queue.items.count) concluído\(queue.items.count == 1 ? "" : "s")")
                    .font(.headline)
                Spacer()
                if queue.isRunning {
                    Button("Cancelar tudo", role: .cancel, action: queue.cancelAll)
                        .controlSize(.small)
                }
                if queue.hasFinished {
                    Button("Limpar concluídos", action: queue.clearFinished)
                        .controlSize(.small)
                }
            }
            List(queue.items) { item in
                QueueRow(item: item, queue: queue)
            }
            .listStyle(.bordered(alternatesRowBackgrounds: true))
        }
    }
}

private struct QueueRow: View {
    let item: QueueItem
    let queue: DownloadQueue

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            icon
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text(item.title ?? item.link)
                    .lineLimit(1)
                    .truncationMode(.middle)
                if item.state == .running {
                    if let progress = item.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                Text(subtitle)
                    .font(.caption)
                    .foregroundStyle(isFailure ? AnyShapeStyle(.red) : AnyShapeStyle(.secondary))
                    .lineLimit(2)
                    .textSelection(.enabled)
            }
            Spacer()
            buttons
        }
        .padding(.vertical, 2)
    }

    private var isFailure: Bool {
        if case .failed = item.state { true } else { false }
    }

    private var subtitle: String {
        switch item.state {
        case .waiting: item.title == nil ? "Aguardando" : "Aguardando · \(item.link)"
        default: item.detail
        }
    }

    @ViewBuilder private var icon: some View {
        switch item.state {
        case .waiting: Image(systemName: "clock").foregroundStyle(.secondary)
        case .running: Image(systemName: "arrow.down.circle.fill").foregroundStyle(Color.sweevi)
        case .done: Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
        case .failed: Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
        case .cancelled: Image(systemName: "xmark.circle").foregroundStyle(.secondary)
        }
    }

    @ViewBuilder private var buttons: some View {
        HStack(spacing: 4) {
            switch item.state {
            case .done:
                Button("Mostrar no Finder", systemImage: "magnifyingglass") { queue.reveal(item) }
            case .failed, .cancelled:
                Button("Tentar de novo", systemImage: "arrow.clockwise") { queue.retry(item.id) }
            case .waiting, .running:
                EmptyView()
            }
            if item.isFinished {
                Button("Remover", systemImage: "xmark") { queue.remove(item.id) }
            }
        }
        .labelStyle(.iconOnly)
        .buttonStyle(.borderless)
    }
}

/// Pasta de destino com o botão para trocá-la.
struct FolderRow: View {
    @ObservedObject var app: AppState

    var body: some View {
        HStack {
            Label(app.folder.lastPathComponent, systemImage: "folder")
                .help(app.folder.path)
            Button("Alterar…", action: app.chooseFolder)
        }
    }
}

/// Logo, nome e uma frase de ajuda, para telas sem conteúdo.
struct EmptyStateView: View {
    let message: String

    var body: some View {
        VStack(spacing: 10) {
            SweeviLogo()
                .frame(width: 96, height: 96)
            Text("Sweevi")
                .font(.largeTitle.bold())
            Text(message)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
