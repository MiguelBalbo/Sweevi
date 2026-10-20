import SwiftUI

struct ContentView: View {
    @ObservedObject var app: AppState

    var body: some View {
        let deps = app.dependencies
        VStack(alignment: .leading, spacing: 14) {
            HStack {
                Picker("Tipo", selection: $app.mode) {
                    ForEach(MediaMode.allCases) { Label($0.title, systemImage: $0.icon).tag($0) }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Picker("Quantidade", selection: $app.isBatch) {
                    Text("Um link").tag(false)
                    Text("Em massa").tag(true)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .fixedSize()
                Spacer()
            }

            let missing = app.missingTools
            if missing.isEmpty {
                if deps.isWorking || deps.taskFinished {
                    TaskConsoleView(deps: deps)
                } else if !deps.updates.isEmpty {
                    UpdateBanner(deps: deps, isBusy: app.queue.isRunning || app.video.isDownloading)
                }
            }

            if !deps.hasLoaded {
                ProgressView("Verificando ferramentas…")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if !missing.isEmpty {
                MissingDependenciesView(deps: deps, mode: app.mode)
            } else if app.mode == .video, !app.isBatch {
                VideoSingleView(model: app.video, app: app)
            } else {
                QueueInputView(app: app)
                if app.queue.items.isEmpty {
                    EmptyStateView(message: app.mode == .video
                        ? "Cole vários links, um por linha, e baixe todos de uma vez."
                        : "Cole um link do Spotify (faixa, álbum ou playlist)\nou escreva “Artista - Música”.")
                } else {
                    QueueListView(queue: app.queue)
                }
                FolderRow(app: app)
                    .disabled(app.queue.isRunning)
            }
        }
        .padding()
        .frame(minWidth: 640, minHeight: 580)
        .tint(.sweevi)
        .toolbar {
            ToolbarItem {
                OpenSettingsButton { app.settingsTab = .cookies }
                    .help("Cookies, tokens e ferramentas instaladas")
            }
        }
        .task { await app.onLaunch() }
    }
}
