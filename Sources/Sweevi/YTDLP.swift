import Foundation

/// Uma atualização emitida durante o download.
enum DownloadEvent: Sendable {
    case title(String)
    case progress(percent: Double?, speed: String, eta: String)
    case postprocessing(String)
    case finished(path: String)
}

/// Executa o binário `yt-dlp` instalado no sistema.
enum YTDLP {
    static var executable: String? { ToolRunner.find("yt-dlp") }

    /// `yt-dlp -J` — busca título, miniatura e formatos disponíveis.
    static func fetchInfo(url: String, extraArguments: [String] = []) async throws -> VideoInfo {
        let output = try await run(["-J", "--no-playlist", "--no-warnings"] + extraArguments + [url])
        do {
            return try JSONDecoder().decode(VideoInfo.self, from: output.stdout)
        } catch {
            throw ToolError.failed("Não foi possível ler a resposta do yt-dlp.")
        }
    }

    /// Baixa `url` com os argumentos de formato informados para `folder`, emitindo eventos de progresso.
    static func download(
        url: String,
        arguments formatArguments: [String],
        folder: URL,
        extraArguments: [String] = [],
        onEvent: @escaping @Sendable (DownloadEvent) -> Void
    ) async throws {
        var args = [
            "--no-playlist",
            "--newline",
            "--progress",
            "--color", "never",
            "--progress-template", "download:DL|%(progress._percent_str)s|%(progress._speed_str)s|%(progress._eta_str)s",
            "--progress-template", "postprocess:PP|%(progress.postprocessor)s",
            "--print", "before_dl:TITLE|%(title)s",
            "--print", "after_move:FILE|%(filepath)s",
            "-P", folder.path,
            "-o", "%(title)s [%(id)s].%(ext)s",
        ]
        if let ffmpeg = ToolRunner.find("ffmpeg") {
            args += ["--ffmpeg-location", ffmpeg]
        }
        args += extraArguments
        args += formatArguments
        args.append(url)

        _ = try await run(args) { line in
            if let event = parse(line) { onEvent(event) }
        }
    }

    private static func parse(_ line: String) -> DownloadEvent? {
        let parts = line.split(separator: "|", omittingEmptySubsequences: false)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        let rest = parts.dropFirst().joined(separator: "|")
        switch parts.first {
        case "DL" where parts.count >= 4:
            let percent = Double(parts[1].replacingOccurrences(of: "%", with: ""))
            return .progress(percent: percent, speed: parts[2], eta: parts[3])
        case "PP" where parts.count >= 2:
            return .postprocessing(parts[1])
        case "TITLE" where parts.count >= 2:
            return .title(rest)
        case "FILE" where parts.count >= 2:
            return .finished(path: rest)
        default:
            return nil
        }
    }

    private static func run(
        _ arguments: [String],
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> ToolRunner.Output {
        guard let executable else { throw ToolError.notInstalled("yt-dlp") }
        let output = try await ToolRunner.run(executable, arguments, onLine: onLine)
        guard output.status == 0 else {
            throw ToolError.failed(ToolRunner.errorMessage(from: output.stderr, fallback: "O yt-dlp terminou com erro."))
        }
        return output
    }
}
