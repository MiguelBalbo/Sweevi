import SwiftUI

/// Mostrado no lugar do conteúdo quando falta alguma ferramenta para o modo atual.
struct MissingDependenciesView: View {
    @ObservedObject var deps: DependencyManager
    let mode: MediaMode

    var body: some View {
        let missing = deps.missing(mode.tools)
        VStack(alignment: .leading, spacing: 14) {
            Label("Falta instalar algumas ferramentas", systemImage: "shippingbox.fill")
                .font(.title3.bold())
            Text("Para baixar \(mode == .video ? "vídeos" : "músicas"), o Sweevi usa estes programas gratuitos:")
                .foregroundStyle(.secondary)

            VStack(alignment: .leading, spacing: 8) {
                ForEach(mode.tools) { ToolStatusRow(tool: $0, status: deps.status($0)) }
            }

            if deps.brewPath == nil {
                Text("Para instalar, o Sweevi usa o Homebrew, que ainda não está no seu Mac. O instalador abre no Terminal e pede a sua senha; quando terminar, volte aqui e clique em Verificar de novo.")
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                HStack {
                    Button("Instalar Homebrew no Terminal", systemImage: "terminal", action: deps.installHomebrewInTerminal)
                        .buttonStyle(.borderedProminent)
                    Button("Verificar de novo") { Task { await deps.refresh() } }
                }
            } else if !deps.isWorking {
                HStack {
                    Button("Instalar \(missing.map(\.name).joined(separator: ", "))", systemImage: "arrow.down.circle.fill") {
                        deps.install(mode.tools)
                    }
                    .buttonStyle(.borderedProminent)
                    Button("Verificar de novo") { Task { await deps.refresh() } }
                }
            }

            TaskConsoleView(deps: deps)
        }
        .padding(20)
        .frame(maxWidth: 520)
        .background(Color(nsColor: .controlBackgroundColor), in: RoundedRectangle(cornerRadius: 12))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

struct ToolStatusRow: View {
    let tool: Tool
    let status: ToolStatus

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: status.isInstalled ? "checkmark.circle.fill" : "xmark.circle.fill")
                .foregroundStyle(status.isInstalled ? .green : .red)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 6) {
                    Text(tool.name).bold()
                    if let version = status.version {
                        Text(version).font(.caption.monospaced()).foregroundStyle(.secondary)
                    }
                }
                Text(status.isInstalled ? "\(tool.purpose) · \(source)" : tool.purpose)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var source: String {
        if status.isFromBrew { return "via Homebrew" }
        if status.isFromPipx { return "via pipx" }
        return status.path ?? ""
    }
}

/// Barra de progresso da instalação/atualização, com o console em "Detalhes".
struct TaskConsoleView: View {
    @ObservedObject var deps: DependencyManager

    var body: some View {
        if !deps.taskTitle.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                HStack {
                    if deps.isWorking {
                        Text(deps.taskTitle)
                    } else if deps.taskError == nil {
                        Label("Concluído", systemImage: "checkmark.circle.fill").foregroundStyle(.green)
                    } else {
                        Label("A operação falhou", systemImage: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    }
                    Spacer()
                    if deps.taskFinished {
                        Button("Fechar", action: deps.dismissTask).controlSize(.small)
                    }
                }
                .font(.callout)

                if deps.isWorking {
                    if let progress = deps.progress {
                        ProgressView(value: progress)
                    } else {
                        ProgressView().progressViewStyle(.linear)
                    }
                }
                if let error = deps.taskError {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                }

                DisclosureGroup("Detalhes", isExpanded: $deps.showConsole) {
                    ConsoleLogView(lines: deps.log)
                }
                .font(.callout)
            }
        }
    }
}

struct ConsoleLogView: View {
    let lines: [String]

    var body: some View {
        ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    Text(lines.isEmpty ? "Sem saída ainda." : lines.joined(separator: "\n"))
                        .font(.caption.monospaced())
                        .foregroundStyle(.white.opacity(0.9))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(8)
                    Color.clear.frame(height: 1).id("end")
                }
            }
            .frame(height: 170)
            .background(Color.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 6))
            .onChange(of: lines.count) { _ in proxy.scrollTo("end", anchor: .bottom) }
            .onAppear { proxy.scrollTo("end", anchor: .bottom) }
        }
    }
}

/// Aviso compacto de atualizações disponíveis.
struct UpdateBanner: View {
    @ObservedObject var deps: DependencyManager
    let isBusy: Bool

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                .font(.title2)
                .foregroundStyle(Color.sweevi)
            VStack(alignment: .leading, spacing: 2) {
                Text("Atualização disponível").bold()
                Text(deps.updates.map { "\($0.tool.name) \($0.current) → \($0.latest)" }.joined(separator: " · "))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button("Atualizar", action: deps.upgradeAll)
                .disabled(isBusy)
                .help(isBusy ? "Espere os downloads terminarem para atualizar." : "")
        }
        .padding(10)
        .background(Color.sweevi.opacity(0.1), in: RoundedRectangle(cornerRadius: 8))
    }
}

/// Aba de Configurações com as versões instaladas e a verificação manual de atualizações.
struct DependenciesPane: View {
    @ObservedObject var app: AppState

    var body: some View {
        let deps = app.dependencies
        VStack(alignment: .leading, spacing: 14) {
            Text("Dependências").font(.title2.bold())
            VStack(alignment: .leading, spacing: 8) {
                ForEach(Tool.allCases) { ToolStatusRow(tool: $0, status: deps.status($0)) }
            }

            HStack {
                Button("Verificar atualizações") { Task { await deps.checkForUpdates(force: true) } }
                    .disabled(deps.isCheckingUpdates || deps.isWorking)
                if deps.isCheckingUpdates {
                    ProgressView().controlSize(.small)
                    Text("Verificando…").font(.caption).foregroundStyle(.secondary)
                } else if let message = deps.updateCheckMessage, deps.updates.isEmpty {
                    Text(message).font(.caption).foregroundStyle(.secondary)
                }
                Spacer()
                let missing = deps.missing(Tool.allCases)
                if !missing.isEmpty, deps.brewPath != nil, !deps.isWorking {
                    Button("Instalar o que falta") { deps.install(Tool.allCases) }
                }
            }

            if !deps.updates.isEmpty, !deps.isWorking {
                UpdateBanner(deps: deps, isBusy: app.queue.isRunning || app.video.isDownloading)
            }
            TaskConsoleView(deps: deps)
            Spacer(minLength: 0)
        }
        .padding(20)
    }
}
