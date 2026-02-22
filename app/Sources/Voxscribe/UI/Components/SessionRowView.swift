import SwiftUI

struct SessionRowView: View {
    let manifest: SessionManifest
    let metadata: String
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(manifest.title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DS.ColorToken.fgPrimary)
                .lineLimit(1)

            Text(metadata)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .lineLimit(1)

            rowStatusContent
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(selected ? DS.ColorToken.bgPanel : DS.ColorToken.bgPanelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(selected ? DS.ColorToken.borderStrong : DS.ColorToken.borderSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }

    @ViewBuilder
    private var rowStatusContent: some View {
        switch manifest.processingState {
        case .running, .queued:
            VStack(alignment: .leading, spacing: 4) {
                CapsLabel(text: manifest.processingStage?.displayLabel ?? "Processing")
                IndexRailView(mode: .progress(manifest.processingProgress ?? 0.15), height: 6)
            }
        case .completed:
            VStack(alignment: .leading, spacing: 4) {
                CapsLabel(text: "Ready")
                if let transcript = try? loadTranscriptSummary() {
                    IndexRailView(mode: .speakerSummary(transcript.segments.prefix(12).map { $0 }), height: 6)
                } else {
                    IndexRailView(mode: .idleTicks, height: 6)
                }
            }
        case .failed:
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle")
                    .font(.system(size: 11))
                CapsLabel(text: "Failed")
            }
        case .cancelled:
            CapsLabel(text: "Cancelled")
        case .notStarted:
            if manifest.recordingState == .recording {
                HStack(spacing: 6) {
                    Circle().fill(DS.ColorToken.fgPrimary).frame(width: 6, height: 6)
                    CapsLabel(text: "REC")
                }
            } else {
                IndexRailView(mode: .idleTicks, height: 6)
            }
        }
    }

    private func loadTranscriptSummary() throws -> TranscriptDocument? {
        let appSupport = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: false)
        let transcriptURL = appSupport
            .appendingPathComponent("com.jesse.voxscribe", isDirectory: true)
            .appendingPathComponent("sessions/\(manifest.id.uuidString)/transcript/transcript.json")
        guard FileManager.default.fileExists(atPath: transcriptURL.path) else { return nil }
        let data = try Data(contentsOf: transcriptURL)
        return try JSONDecoder().decode(TranscriptDocument.self, from: data)
    }
}

