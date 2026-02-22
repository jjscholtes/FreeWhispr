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

    struct SpeakerPresentation {
        let badgeLabel: String
        let badgeStyleIndex: Int
        let title: String
        let subtitle: String
    }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Text(TranscriptExporter.formatHumanTimestamp(segment.startMs))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .frame(width: 84, alignment: .leading)
                .padding(.top, 8)

            Menu {
                Button("Assign to Unassigned") { onAssignSpeaker(nil) }
                if !speakerOptions.isEmpty {
                    Divider()
                    ForEach(speakerOptions, id: \.id) { option in
                        Button("Assign to \(option.label)") { onAssignSpeaker(option.id) }
                    }
                } else {
                    Divider()
                    Button("No speakers available") {}
                        .disabled(true)
                }
            } label: {
                SpeakerAssignmentControlLabel(presentation: speakerPresentation)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 360, alignment: .leading)
            .layoutPriority(1)
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

    private var speakerPresentation: SpeakerPresentation {
        guard let speakerId = segment.speakerId else {
            return SpeakerPresentation(
                badgeLabel: "UN",
                badgeStyleIndex: 4,
                title: "Unassigned",
                subtitle: "No speaker assigned"
            )
        }

        if let index = transcript.speakers.firstIndex(where: { $0.id == speakerId }) {
            let speaker = transcript.speakers[index]
            return SpeakerPresentation(
                badgeLabel: "S\(index + 1)",
                badgeStyleIndex: index + 1,
                title: speaker.effectiveLabel,
                subtitle: "Speaker S\(index + 1)"
            )
        }

        return SpeakerPresentation(
            badgeLabel: "??",
            badgeStyleIndex: 4,
            title: "Unknown speaker",
            subtitle: "Missing speaker reference"
        )
    }

    private func commitIfNeeded() {
        let trimmedNewlineNormalized = draftText.replacingOccurrences(of: "\r\n", with: "\n")
        let currentNormalized = lastCommittedText.replacingOccurrences(of: "\r\n", with: "\n")
        guard trimmedNewlineNormalized != currentNormalized else { return }
        onCommitText(draftText)
        lastCommittedText = draftText
    }
}

private struct SpeakerAssignmentControlLabel: View {
    let presentation: TranscriptSegmentRowView.SpeakerPresentation

    var body: some View {
        HStack(alignment: .center, spacing: 8) {
            SpeakerBadgeView(label: presentation.badgeLabel, styleIndex: presentation.badgeStyleIndex)

            VStack(alignment: .leading, spacing: 2) {
                Text(presentation.title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)
                Text(presentation.subtitle)
                    .font(.system(size: 10, weight: .medium, design: .monospaced))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(1)

            Image(systemName: "chevron.down")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(DS.ColorToken.fgSecondary)
                .padding(.top, 1)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(DS.ColorToken.controlBg)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .stroke(DS.ColorToken.controlBorder, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
    }
}
