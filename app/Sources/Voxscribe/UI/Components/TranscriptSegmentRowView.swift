import SwiftUI

struct TranscriptSegmentRowView: View {
    let segment: TranscriptSegment
    let transcript: TranscriptDocument
    let speakerOptions: [(id: String, label: String)]
    let onCommitText: (String) -> Void
    let onAssignSpeaker: (String?) -> Void

    @State private var draftText: String = ""
    @State private var lastCommittedText: String = ""
    @State private var isSpeakerPickerPresented = false
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

            Button {
                isSpeakerPickerPresented.toggle()
            } label: {
                SpeakerAssignmentControlLabel(presentation: speakerPresentation)
            }
            .buttonStyle(.plain)
            .frame(minWidth: 240, idealWidth: 290, maxWidth: 360, alignment: .leading)
            .layoutPriority(1)
            .padding(.top, 4)
            .help("Assign a speaker to this transcript segment.")
            .popover(isPresented: $isSpeakerPickerPresented, arrowEdge: .top) {
                SpeakerAssignmentPopover(
                    speakerOptions: speakerOptions,
                    onAssignSpeaker: { speakerId in
                        onAssignSpeaker(speakerId)
                        isSpeakerPickerPresented = false
                    }
                )
            }

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

private struct SpeakerAssignmentPopover: View {
    let speakerOptions: [(id: String, label: String)]
    let onAssignSpeaker: (String?) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Assign Speaker")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(DS.ColorToken.fgPrimary)

            VStack(spacing: 6) {
                Button {
                    onAssignSpeaker(nil)
                } label: {
                    rowLabel("Unassigned", subtitle: "No speaker assigned")
                }
                .buttonStyle(.plain)

                if !speakerOptions.isEmpty {
                    Divider()
                    ForEach(speakerOptions, id: \.id) { option in
                        Button {
                            onAssignSpeaker(option.id)
                        } label: {
                            rowLabel(option.label, subtitle: "Assign to transcript row")
                        }
                        .buttonStyle(.plain)
                    }
                } else {
                    Divider()
                    Text("No speakers available")
                        .font(.system(size: 12))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                        .padding(.horizontal, 8)
                        .padding(.vertical, 6)
                }
            }
        }
        .padding(12)
        .frame(width: 280)
        .background(DS.ColorToken.bgApp)
    }

    private func rowLabel(_ title: String, subtitle: String) -> some View {
        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                Text(subtitle)
                    .font(.system(size: 10))
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }
            Spacer()
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(DS.ColorToken.bgPanelAlt)
        .overlay(
            RoundedRectangle(cornerRadius: DS.Radius.sm)
                .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
        )
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
        .contentShape(RoundedRectangle(cornerRadius: DS.Radius.sm))
    }
}
