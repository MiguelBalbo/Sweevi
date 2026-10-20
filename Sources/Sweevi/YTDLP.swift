import Foundation

enum YTDLPError: LocalizedError {
    case notInstalled
    case failed(String)
    case invalidOutput

    var errorDescription: String? {
        switch self {
        case .notInstalled:
            "yt-dlp não encontrado. Instale com: brew install yt-dlp ffmpeg"
        case .failed(let message):
            message
        case .invalidOutput:
            "Não foi possível ler a resposta do yt-dlp."
        }
    }
}

/// Uma atualização emitida durante o download.
enum DownloadEvent: Sendable {
    case progress(percent: Double?, speed: String, eta: String)
    case postprocessing(String)
    case finished(path: String)
}

/// Executa o binário `yt-dlp` instalado no sistema.
enum YTDLP {
    /// Apps GUI não herdam o PATH do shell, então procuramos nos locais comuns.
    static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        "/usr/bin",
    ]

    static func find(_ name: String) -> String? {
        searchPaths
            .map { $0 + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var executable: String? { find("yt-dlp") }

    /// `yt-dlp -J` — busca título, miniatura e formatos disponíveis.
    static func fetchInfo(url: String) async throws -> VideoInfo {
        let result = try await run(["-J", "--no-playlist", "--no-warnings", url])
        do {
            return try JSONDecoder().decode(VideoInfo.self, from: result.stdout)
        } catch {
            throw YTDLPError.invalidOutput
        }
    }

    /// Baixa `url` com a opção escolhida para `folder`, emitindo eventos de progresso.
    static func download(
        url: String,
        option: DownloadOption,
        folder: URL,
        onEvent: @escaping @Sendable (DownloadEvent) -> Void
    ) async throws {
        var args = [
            "--no-playlist",
            "--newline",
            "--progress",
            "--color", "never",
            "--progress-template", "download:DL|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--progress-template", "postprocess:PP|%(progress.postprocessor)s",
            "--print", "after_move:FILE|%(filepath)s",
            "-P", folder.path,
            "-o", "%(title)s [%(id)s].%(ext)s",
        ]
        if let ffmpeg = find("ffmpeg") {
            args += ["--ffmpeg-location", ffmpeg]
        }
        args += option.arguments
        args.append(url)

        _ = try await run(args) { line in
            if let event = parse(line) { onEvent(event) }
        }
    }

    private static func parse(_ line: String) -> DownloadEvent? {
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        switch parts.first {
        case "DL" where parts.count >= 4:
            let percent = Double(parts[1].replacingOccurrences(of: "%", with: ""))
            return .progress(percent: percent, speed: parts[2], eta: parts[3])
        case "PP" where parts.count >= 2:
            return .postprocessing(parts[1])
        case "FILE" where parts.count >= 2:
            return .finished(path: parts.dropFirst().joined(separator: "|"))
        default:
            return nil
        }
    }

    // MARK: - Execução do processo

    private struct Output {
        let stdout: Data
        let stderr: String
    }

    /// Roda o yt-dlp. Se `onLine` for informado, cada linha de stdout/stderr é entregue a ele.
    /// Cancelar a Task encerra o processo.
    private static func run(
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        guard let executable else { throw YTDLPError.notInstalled }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + [env["PATH"] ?? ""]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        process.environment = env

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        let out = StreamCollector(onLine: onLine)
        let err = StreamCollector(onLine: onLine)

        let status: Int32 = try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                outPipe.fileHandleForReading.readabilityHandler = { out.append($0.availableData) }
                errPipe.fileHandleForReading.readabilityHandler = { err.append($0.availableData) }
                process.terminationHandler = { p in
                    outPipe.fileHandleForReading.readabilityHandler = nil
                    errPipe.fileHandleForReading.readabilityHandler = nil
                    out.append(outPipe.fileHandleForReading.readDataToEndOfFile())
                    err.append(errPipe.fileHandleForReading.readDataToEndOfFile())
                    out.flush()
                    err.flush()
                    continuation.resume(returning: p.terminationStatus)
                }
                do {
                    try process.run()
                } catch {
                    process.terminationHandler = nil
                    continuation.resume(throwing: error)
                }
            }
        } onCancel: {
            if process.isRunning { process.terminate() }
        }

        try Task.checkCancellation()
        let stderr = String(decoding: err.data, as: UTF8.self)
        guard status == 0 else {
            throw YTDLPError.failed(errorMessage(from: stderr))
        }
        return Output(stdout: out.data, stderr: stderr)
    }

    private static func errorMessage(from stderr: String) -> String {
        let lines = stderr.split(whereSeparator: \.isNewline).map(String.init)
        if let error = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return String(error.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        return lines.last ?? "O yt-dlp terminou com erro."
    }
}

/// Acumula a saída de um pipe e, opcionalmente, a entrega linha a linha.
private final class StreamCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var buffer = Data()
    private var pending = Data()
    private let onLine: (@Sendable (String) -> Void)?

    init(onLine: (@Sendable (String) -> Void)?) {
        self.onLine = onLine
    }

    var data: Data { lock.withLock { buffer } }

    func append(_ chunk: Data) {
        guard !chunk.isEmpty else { return }
        let lines: [String] = lock.withLock {
            buffer.append(chunk)
            guard onLine != nil else { return [] }
            pending.append(chunk)
            var lines: [String] = []
            while let index = pending.firstIndex(where: { $0 == 0x0A || $0 == 0x0D }) {
                let line = pending[pending.startIndex..<index]
                pending.removeSubrange(pending.startIndex...index)
                if !line.isEmpty { lines.append(String(decoding: line, as: UTF8.self)) }
            }
            return lines
        }
        lines.forEach { onLine?($0) }
    }

    func flush() {
        let rest: String? = lock.withLock {
            defer { pending.removeAll() }
            return pending.isEmpty ? nil : String(decoding: pending, as: UTF8.self)
        }
        if let rest { onLine?(rest) }
    }
}
