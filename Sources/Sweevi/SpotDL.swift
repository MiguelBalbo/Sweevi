import Foundation

/// Uma atualização emitida pelo spotdl durante o download.
enum MusicEvent: Sendable {
    /// Música atual e a etapa em que está ("Downloading", "Embedding metadata"...).
    case stage(song: String, stage: String)
    /// `done` de `total` músicas deste link já processadas.
    case progress(done: Int, total: Int)
    case downloaded(song: String)
    case skipped(song: String)
    case problem(String)
}

/// Executa o `spotdl` (instalado pelo pipx) para baixar músicas.
enum SpotDL {
    static var executable: String? { ToolRunner.find("spotdl") }

    /// Baixa um link do Spotify (faixa, álbum, playlist) ou uma busca ("Artista - Música") para `folder`.
    static func download(
        query: String,
        format: MusicFormat,
        bitrate: MusicBitrate,
        folder: URL,
        extraArguments: [String] = [],
        onEvent: @escaping @Sendable (MusicEvent) -> Void
    ) async throws {
        guard let executable else { throw ToolError.notInstalled("spotdl") }
        var args = [
            "download", query,
            "--simple-tui",
            "--print-errors",
            "--format", format.rawValue,
            "--bitrate", bitrate.rawValue,
            "--output", "{artists} - {title}.{output-ext}",
        ]
        if let ffmpeg = ToolRunner.find("ffmpeg") {
            args += ["--ffmpeg", ffmpeg]
        }
        args += extraArguments

        let output = try await ToolRunner.run(executable, args, currentDirectory: folder) { line in
            if let event = parse(line) { onEvent(event) }
        }
        guard output.status == 0 else {
            throw ToolError.failed(ToolRunner.errorMessage(
                from: output.stdoutText + "\n" + output.stderr,
                fallback: "O spotdl terminou com erro."
            ))
        }
    }

    private static let stages: Set<String> = [
        "Searching for song", "Getting audio meta", "Downloading", "Converting",
        "Embedding metadata", "Done", "Skipped",
    ]

    static func parse(_ raw: String) -> MusicEvent? {
        let line = raw.trimmingCharacters(in: .whitespaces)
        if let match = line.captures(#"^(\d+)/(\d+) complete$"#), let done = Int(match[0]), let total = Int(match[1]) {
            return .progress(done: done, total: total)
        }
        if let match = line.captures(#"^Downloaded "(.+)":"#) {
            return .downloaded(song: match[0])
        }
        if let match = line.captures(#"^Skipping (.+?) \(file already exists\)"#) {
            return .skipped(song: match[0])
        }
        if let match = line.captures(#"^(.+): ([A-Za-z ]+)$"#), stages.contains(match[1]) {
            return .stage(song: match[0], stage: match[1])
        }
        if line.range(of: #"^\w*(Error|Exception):"#, options: .regularExpression) != nil
            || line.contains("No results found") {
            return .problem(line)
        }
        return nil
    }
}
