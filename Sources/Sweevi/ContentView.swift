import SwiftUI

struct ContentView: View {
    @State private var model = DownloaderModel()
    @State private var showAllFormats = false

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            urlBar

            if !model.isInstalled {
                Label("yt-dlp não encontrado. Instale no Terminal com: brew install yt-dlp ffmpeg",
                      systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
            }

            if let info = model.info {
                header(info)
                optionsList
                footer
            } else if model.isFetching {
                ProgressView("Buscando informações…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                emptyState
            }

            if let error = model.errorMessage {
                Text(error)
                    .foregroundStyle(.red)
                    .textSelection(.enabled)
            }
        }
        .padding()
        .frame(minWidth: 560, minHeight: 520)
        .tint(.sweevi)
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            SweeviLogo()
                .frame(width: 96, height: 96)
            Text("Sweevi")
                .font(.largeTitle.bold())
            Text("Cole um link do YouTube, Vimeo, Instagram, X, TikTok\ne de milhares de outros sites.")
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var urlBar: some View {
        HStack {
            TextField("https://…", text: $model.url)
                .textFieldStyle(.roundedBorder)
                .onSubmit(model.fetch)
            Button("Colar", systemImage: "doc.on.clipboard", action: model.paste)
                .labelStyle(.iconOnly)
                .help("Colar link")
            Button("Buscar", action: model.fetch)
                .keyboardShortcut(.defaultAction)
                .disabled(!model.canFetch)
        }
        .disabled(model.isDownloading)
    }

    private func header(_ info: VideoInfo) -> some View {
        HStack(alignment: .top, spacing: 12) {
            AsyncImage(url: info.thumbnail.flatMap(URL.init(string:))) { image in
                image.resizable().aspectRatio(contentMode: .fill)
            } placeholder: {
                Rectangle().fill(.quaternary)
            }
            .frame(width: 160, height: 90)
            .clipShape(RoundedRectangle(cornerRadius: 6))

            VStack(alignment: .leading, spacing: 4) {
                Text(info.title)
                    .font(.headline)
                    .lineLimit(3)
                    .textSelection(.enabled)
                if let uploader = info.uploader {
                    Text(uploader).foregroundStyle(.secondary)
                }
                Text([info.durationText, info.extractor].compactMap { $0 }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var optionsList: some View {
        List(selection: $model.selectedID) {
            Section("Opções de download") {
                ForEach(model.options) { row($0) }
            }
            if !model.rawOptions.isEmpty {
                Section("Todos os formatos", isExpanded: $showAllFormats) {
                    ForEach(model.rawOptions) { row($0) }
                }
            }
        }
        .listStyle(.sidebar)
        .disabled(model.isDownloading)
    }

    private func row(_ option: DownloadOption) -> some View {
        HStack {
            Text(option.title)
            Spacer()
            if let detail = option.detail {
                Text(detail)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .tag(option.id)
    }

    private var footer: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Label(model.folder.lastPathComponent, systemImage: "folder")
                    .help(model.folder.path)
                Button("Alterar…", action: model.chooseFolder)
                    .disabled(model.isDownloading)
                Spacer()
                if model.isDownloading {
                    Button("Cancelar", role: .cancel, action: model.cancel)
                } else {
                    Button("Baixar", systemImage: "arrow.down.circle.fill", action: model.download)
                        .buttonStyle(.borderedProminent)
                        .disabled(model.selectedOption == nil)
                }
            }

            if model.isDownloading || !model.status.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    if model.isDownloading {
                        if let progress = model.progress {
                            ProgressView(value: progress)
                        } else {
                            ProgressView().progressViewStyle(.linear)
                        }
                    }
                    HStack {
                        Text(model.status)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                        Spacer()
                        if !model.isDownloading, model.downloadedFile != nil {
                            Button("Mostrar no Finder", action: model.revealInFinder)
                                .controlSize(.small)
                        }
                    }
                }
            }
        }
    }
}
