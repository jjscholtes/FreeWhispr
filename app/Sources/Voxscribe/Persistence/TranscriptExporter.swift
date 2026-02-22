import Foundation

struct ExportFormatSelection: Sendable, Equatable {
    var includeJSON: Bool = true
    var includeTXT: Bool = true
    var includeSRT: Bool = true

    var hasAnySelection: Bool { includeJSON || includeTXT || includeSRT }
}

struct UserExportResult: Sendable {
    let directoryURL: URL
    let exportedURLs: [URL]
}

struct TranscriptExporter {
    static func exportAll(_ transcript: TranscriptDocument, to sessionDirectory: URL, using store: SessionStore) async throws -> ArtifactStatus {
        let transcriptDir = sessionDirectory.appendingPathComponent("transcript", isDirectory: true)
        let txt = buildTXT(transcript)
        let srt = buildSRT(transcript)
        try await store.writeTextFile(txt, to: transcriptDir.appendingPathComponent("transcript.txt"))
        try await store.writeTextFile(srt, to: transcriptDir.appendingPathComponent("transcript.srt"))
        try await store.saveTranscript(transcript)
        return ArtifactStatus(hasTranscriptJson: true, hasTxtExport: true, hasSrtExport: true)
    }

    static func exportForUser(
        _ transcript: TranscriptDocument,
        to directory: URL,
        baseFilename: String,
        selection: ExportFormatSelection
    ) throws -> UserExportResult {
        let fm = FileManager.default
        try fm.createDirectory(at: directory, withIntermediateDirectories: true, attributes: nil)
        guard selection.hasAnySelection else {
            throw NSError(domain: "KopieExport", code: 1, userInfo: [NSLocalizedDescriptionKey: "Select at least one export format."])
        }

        let stem = baseFilename.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "transcript" : baseFilename
        var exportedURLs: [URL] = []

        if selection.includeJSON {
            let jsonURL = directory.appendingPathComponent("\(stem).json")
            try transcript.encodedData().write(to: jsonURL, options: .atomic)
            exportedURLs.append(jsonURL)
        }
        if selection.includeTXT {
            let txtURL = directory.appendingPathComponent("\(stem).txt")
            try Data(buildTXT(transcript).utf8).write(to: txtURL, options: .atomic)
            exportedURLs.append(txtURL)
        }
        if selection.includeSRT {
            let srtURL = directory.appendingPathComponent("\(stem).srt")
            try Data(buildSRT(transcript).utf8).write(to: srtURL, options: .atomic)
            exportedURLs.append(srtURL)
        }

        return UserExportResult(directoryURL: directory, exportedURLs: exportedURLs)
    }

    static func buildTXT(_ transcript: TranscriptDocument) -> String {
        transcript.segments.map { segment in
            "[\(formatHumanTimestamp(segment.startMs))] \(transcript.speakerLabel(for: segment.speakerId)): \(segment.text)"
        }.joined(separator: "\n") + "\n"
    }

    static func buildSRT(_ transcript: TranscriptDocument) -> String {
        var lines: [String] = []
        for (index, segment) in transcript.segments.enumerated() {
            lines.append(String(index + 1))
            lines.append("\(formatSRTTimestamp(segment.startMs)) --> \(formatSRTTimestamp(segment.endMs))")
            lines.append("\(transcript.speakerLabel(for: segment.speakerId)): \(segment.text)")
            lines.append("")
        }
        return lines.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }

    static func formatHumanTimestamp(_ ms: Int) -> String {
        let hours = ms / 3_600_000
        let minutes = (ms % 3_600_000) / 60_000
        let seconds = (ms % 60_000) / 1000
        return String(format: "%02d:%02d:%02d", hours, minutes, seconds)
    }

    static func formatSRTTimestamp(_ ms: Int) -> String {
        let hours = ms / 3_600_000
        let minutes = (ms % 3_600_000) / 60_000
        let seconds = (ms % 60_000) / 1000
        let millis = ms % 1000
        return String(format: "%02d:%02d:%02d,%03d", hours, minutes, seconds, millis)
    }
}
