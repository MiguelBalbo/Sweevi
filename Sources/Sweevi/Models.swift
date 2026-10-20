import Foundation

/// Informações do vídeo retornadas por `yt-dlp -J`.
struct VideoInfo: Decodable, Sendable {
    let id: String
    let title: String
    let thumbnail: String?
    let duration: Double?
    let uploader: String?
    let extractor: String?
    let formats: [Format]?

    var durationText: String? {
        guard let duration, duration > 0 else { return nil }
        let total = Int(duration)
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }
}

struct Format: Decodable, Sendable, Identifiable {
    let formatId: String
    let ext: String?
    let height: Int?
    let width: Int?
    let fps: Double?
    let vcodec: String?
    let acodec: String?
    let filesize: Int64?
    let filesizeApprox: Int64?
    let formatNote: String?
    let tbr: Double?

    var id: String { formatId }

    enum CodingKeys: String, CodingKey {
        case formatId = "format_id"
        case ext, height, width, fps, vcodec, acodec, filesize, tbr
        case filesizeApprox = "filesize_approx"
        case formatNote = "format_note"
    }

    var hasVideo: Bool { vcodec != nil && vcodec != "none" }
    var hasAudio: Bool { acodec != nil && acodec != "none" }
    var size: Int64? { filesize ?? filesizeApprox }

    /// Descrição legível de um formato bruto.
    var summary: String {
        var parts: [String] = []
        if hasVideo {
            if let width, let height { parts.append("\(width)x\(height)") }
            else if let height { parts.append("\(height)p") }
            if let fps, fps > 0 { parts.append("\(Int(fps))fps") }
        }
        switch (hasVideo, hasAudio) {
        case (true, true): parts.append("vídeo+áudio")
        case (true, false): parts.append("só vídeo")
        case (false, true): parts.append("só áudio")
        default: break
        }
        if let note = formatNote, !note.isEmpty { parts.append(note) }
        return parts.joined(separator: " · ")
    }
}

/// Uma opção de download mostrada ao usuário.
struct DownloadOption: Identifiable, Hashable, Sendable {
    let id: String
    let title: String
    let detail: String?
    let arguments: [String]

    /// Monta as opções principais a partir dos formatos do vídeo.
    static func options(for info: VideoInfo) -> [DownloadOption] {
        let formats = info.formats ?? []
        var result: [DownloadOption] = [
            DownloadOption(
                id: "best",
                title: "Melhor qualidade (vídeo + áudio)",
                detail: "MP4 quando possível",
                arguments: ["-f", "bv*+ba/b", "--merge-output-format", "mp4"]
            )
        ]

        // Uma opção por altura disponível (2160p, 1080p, 720p...).
        let bestAudioSize = formats.filter { $0.hasAudio && !$0.hasVideo }.compactMap(\.size).max() ?? 0
        let heights = Set(formats.filter(\.hasVideo).compactMap(\.height)).sorted(by: >)
        for height in heights {
            let videoSize = formats.filter { $0.hasVideo && $0.height == height }.compactMap(\.size).max()
            let detail = videoSize.map { "≈ " + ByteCountFormatter.string(fromByteCount: $0 + bestAudioSize, countStyle: .file) }
            result.append(DownloadOption(
                id: "h\(height)",
                title: "\(height)p",
                detail: detail,
                arguments: ["-f", "bv*[height=\(height)]+ba/b[height=\(height)]", "--merge-output-format", "mp4"]
            ))
        }

        result.append(DownloadOption(
            id: "mp3",
            title: "Somente áudio (MP3)",
            detail: nil,
            arguments: ["-f", "ba/b", "-x", "--audio-format", "mp3"]
        ))
        return result
    }

    /// Opção para baixar um formato bruto específico.
    static func raw(_ format: Format) -> DownloadOption {
        var detail = format.summary
        if let size = format.size {
            detail += " · " + ByteCountFormatter.string(fromByteCount: size, countStyle: .file)
        }
        return DownloadOption(
            id: "raw-\(format.formatId)",
            title: "\(format.formatId) (\(format.ext ?? "?"))",
            detail: detail,
            arguments: ["-f", format.formatId]
        )
    }
}
