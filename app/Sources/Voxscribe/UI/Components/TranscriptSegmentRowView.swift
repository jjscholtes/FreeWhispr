import SwiftUI

struct TranscriptSegmentRowView: View {
    let segment: TranscriptSegment
    let transcript: TranscriptDocument
    let speakerOptions: [(id: String, label: String)]
    let onCommitText: (String) -> Void
    let onAssignSpeaker: (String?) -> Void

    @State private var draftText: String = ""
    @State private var lastCommittedText: String = ""
    @FocusState private var isFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(TranscriptExporter.formatHumanTimestamp(segment.startMs))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .frame(width: 84, alignment: .leading)
                .padding(.top, 8)

            Menu {
                Button("Assign to Unassigned") { onAssignSpeaker(nil) }
                Divider()
                ForEach(speakerOptions, id: \.id) { option in
                    Button("Assign to \(option.label)") { onAssignSpeaker(option.id) }
                }
            } label: {
                HStack(alignment: .top, spacing: 6) {
                    SpeakerBadgeView(label: badgeLabel, styleIndex: badgeStyleIndex)
                        .padding(.top, 1)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Speaker")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                        Text(speakerDisplayLabel)
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(DS.ColorToken.fgPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .menuStyle(.borderlessButton)
            .frame(minWidth: 230, idealWidth: 270, maxWidth: 320, alignment: .leading)
            .padding(.top, 4)
            .help("Assign a speaker to this transcript segment.")

            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    if segment.source == .userEdited {
                        CapsLabel(text: "Edited")
                    }
                    if isFocused && draftText != lastCommittedText {
                        Text("Unsaved")
                            .font(.system(size: 11, weight: .medium))
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                    }
                }

                TextField("", text: $draftText, axis: .vertical)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14))
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                    .focused($isFocused)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 8)
                    .background(isFocused ? Color.white : Color.clear)
                    .overlay(
                        RoundedRectangle(cornerRadius: DS.Radius.sm)
                            .stroke(isFocused ? DS.ColorToken.borderStrong : Color.clear, lineWidth: 1)
                    )
                    .onSubmit {
                        commitIfNeeded()
                    }
                    .onChange(of: isFocused) { _, focused in
                        if !focused {
                            commitIfNeeded()
                        }
                    }
                    .onChange(of: segment.text) { _, newValue in
                        if !isFocused {
                            draftText = newValue
                            lastCommittedText = newValue
                        }
                    }
                    .onAppear {
                        draftText = segment.text
                        lastCommittedText = segment.text
                    }
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .background(isFocused ? Color.white : DS.ColorToken.bgPanelAlt.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.md)
                .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
        )
    }

    private var badgeLabel: String {
        guard let speakerId = segment.speakerId else { return "UN" }
        if let speaker = transcript.speakers.first(where: { $0.id == speakerId }) {
            if let index = transcript.speakers.firstIndex(where: { $0.id == speakerId }) {
                return "S\(index + 1)"
            }
            return String(speaker.effectiveLabel.prefix(2)).uppercased()
        }
        return "UN"
    }

    private var badgeStyleIndex: Int {
        guard let speakerId = segment.speakerId,
              let index = transcript.speakers.firstIndex(where: { $0.id == speakerId }) else { return 4 }
        return index + 1
    }

    private var speakerDisplayLabel: String {
        transcript.speakerLabel(for: segment.speakerId)
    }

    private func commitIfNeeded() {
        let trimmedNewlineNormalized = draftText.replacingOccurrences(of: "\r\n", with: "\n")
        let currentNormalized = lastCommittedText.replacingOccurrences(of: "\r\n", with: "\n")
        guard trimmedNewlineNormalized != currentNormalized else { return }
        onCommitText(draftText)
        lastCommittedText = draftText
    }
}
