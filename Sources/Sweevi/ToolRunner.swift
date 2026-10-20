import Foundation

enum ToolError: LocalizedError {
    case notInstalled(String)
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .notInstalled(let name): "\(name) não está instalado."
        case .failed(let message): message
        }
    }
}

/// Encontra e executa as ferramentas de linha de comando (yt-dlp, ffmpeg, spotdl, brew, pipx).
enum ToolRunner {
    /// Apps GUI não herdam o PATH do shell, então procuramos nos locais comuns
    /// (Homebrew no Apple Silicon e no Intel, e o `~/.local/bin` do pipx).
    static let searchPaths: [String] = [
        "/opt/homebrew/bin",
        "/usr/local/bin",
        NSHomeDirectory() + "/.local/bin",
        "/usr/bin",
    ]

    /// Para testar o painel de dependências: `SWEEVI_FAKE_MISSING=yt-dlp,spotdl`.
    private static let fakeMissing: Set<String> = Set(
        (ProcessInfo.processInfo.environment["SWEEVI_FAKE_MISSING"] ?? "")
            .split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
    )

    static func find(_ name: String) -> String? {
        guard !fakeMissing.contains(name) else { return nil }
        return searchPaths
            .map { $0 + "/" + name }
            .first { FileManager.default.isExecutableFile(atPath: $0) }
    }

    static var environment: [String: String] {
        var env = ProcessInfo.processInfo.environment
        env["PATH"] = (searchPaths + [env["PATH"] ?? "/bin:/usr/sbin:/sbin"]).joined(separator: ":")
        env["PYTHONUNBUFFERED"] = "1"
        env["COLUMNS"] = "400"  // evita que o spotdl quebre as linhas em 80 colunas
        env["NO_COLOR"] = "1"
        env["HOMEBREW_NO_ENV_HINTS"] = "1"
        env["HOMEBREW_NO_COLOR"] = "1"
        return env
    }

    struct Output: Sendable {
        let status: Int32
        let stdout: Data
        let stderr: String

        var stdoutText: String { String(decoding: stdout, as: UTF8.self) }
    }

    /// Roda `executable`. Se `onLine` for informado, cada linha de stdout/stderr é entregue a ele.
    /// Cancelar a Task encerra o processo (e lança `CancellationError`).
    static func run(
        _ executable: String,
        _ arguments: [String],
        currentDirectory: URL? = nil,
        onLine: (@Sendable (String) -> Void)? = nil
    ) async throws -> Output {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.environment = environment
        if let currentDirectory { process.currentDirectoryURL = currentDirectory }

        let outPipe = Pipe(), errPipe = Pipe()
        process.standardOutput = outPipe
        process.standardError = errPipe
        process.standardInput = FileHandle.nullDevice
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
            guard process.isRunning else { return }
            let pid = process.processIdentifier
            process.terminate()
            // O spotdl (Python) às vezes demora para sair com SIGTERM; força depois de 3 s.
            DispatchQueue.global().asyncAfter(deadline: .now() + 3) {
                if kill(pid, 0) == 0 { kill(pid, SIGKILL) }
            }
        }

        try Task.checkCancellation()
        return Output(status: status, stdout: out.data, stderr: String(decoding: err.data, as: UTF8.self))
    }

    /// A linha de erro mais útil de uma saída: a última `ERROR:` ou `...Error: ...`, senão a última linha.
    static func errorMessage(from text: String, fallback: String) -> String {
        let lines = text.split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && !$0.hasPrefix("│") && !$0.hasPrefix("╭") && !$0.hasPrefix("╰") }
        if let line = lines.last(where: { $0.hasPrefix("ERROR:") }) {
            return String(line.dropFirst("ERROR:".count)).trimmingCharacters(in: .whitespaces)
        }
        if let line = lines.last(where: { $0.range(of: #"^\w*(Error|Exception):"#, options: .regularExpression) != nil }) {
            return line
        }
        return lines.last ?? fallback
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

extension String {
    /// Grupos capturados na primeira ocorrência de `pattern` (NSRegularExpression, compatível com macOS 12).
    func captures(_ pattern: String) -> [String]? {
        allCaptures(pattern).first
    }

    /// Grupos capturados em todas as ocorrências de `pattern`.
    func allCaptures(_ pattern: String) -> [[String]] {
        guard let regex = try? NSRegularExpression(pattern: pattern) else { return [] }
        return regex.matches(in: self, range: NSRange(startIndex..., in: self)).map { match in
            (1..<match.numberOfRanges).map { index in
                Range(match.range(at: index), in: self).map { String(self[$0]) } ?? ""
            }
        }
    }
}
