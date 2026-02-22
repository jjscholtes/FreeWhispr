import SwiftUI

struct IndexRailView: View {
    enum Mode {
        case idleTicks
        case progress(Double)
        case live([Double])
        case speakerSummary([TranscriptSegment])
    }

    var mode: Mode
    var height: CGFloat = 8

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: .leading) {
                RoundedRectangle(cornerRadius: height / 2)
                    .fill(DS.ColorToken.bgPanelAlt)
                    .overlay(
                        RoundedRectangle(cornerRadius: height / 2)
                            .stroke(DS.ColorToken.borderSoft, lineWidth: 1)
                    )

                switch mode {
                case .idleTicks:
                    HStack(spacing: 6) {
                        ForEach(0..<24, id: \.self) { _ in
                            Rectangle()
                                .fill(DS.ColorToken.borderStrong)
                                .frame(width: 2, height: height - 2)
                        }
                    }
                    .padding(.horizontal, 6)

                case .progress(let fraction):
                    RoundedRectangle(cornerRadius: height / 2)
                        .fill(DS.ColorToken.fgPrimary)
                        .frame(width: max(6, proxy.size.width * max(0, min(1, fraction))))

                case .live(let samples):
                    HStack(alignment: .center, spacing: 2) {
                        ForEach(Array(samples.enumerated()), id: \.offset) { _, sample in
                            RoundedRectangle(cornerRadius: 1)
                                .fill(DS.ColorToken.fgPrimary)
                                .frame(width: max(2, (proxy.size.width - CGFloat(samples.count * 2)) / CGFloat(max(1, samples.count))),
                                       height: max(2, (height - 1) * CGFloat(0.2 + (sample * 0.8))))
                        }
                    }
                    .frame(height: height, alignment: .center)
                    .padding(.horizontal, 4)

                case .speakerSummary(let segments):
                    HStack(spacing: 1) {
                        if segments.isEmpty {
                            Rectangle()
                                .fill(DS.ColorToken.borderSoft)
                        } else {
                            ForEach(segments) { segment in
                                Rectangle()
                                    .fill(fillStyle(for: segment.speakerId))
                                    .frame(maxWidth: .infinity)
                                    .overlay(
                                        Rectangle()
                                            .strokeBorder(DS.ColorToken.fgPrimary.opacity(patternBorderOpacity(for: segment.speakerId)), style: StrokeStyle(lineWidth: 0.4, dash: dash(for: segment.speakerId)))
                                    )
                            }
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: height / 2))
                    .padding(1)
                }
            }
        }
        .frame(height: height)
    }

    private func fillStyle(for speakerId: String?) -> some ShapeStyle {
        switch speakerVariant(for: speakerId) {
        case 1:
            return DS.ColorToken.fgPrimary
        case 2:
            return DS.ColorToken.bgPanelAlt
        case 3:
            return DS.ColorToken.bgPanel
        default:
            return DS.ColorToken.bgPanelAlt
        }
    }

    private func patternBorderOpacity(for speakerId: String?) -> Double {
        speakerVariant(for: speakerId) == 1 ? 0 : 0.6
    }

    private func dash(for speakerId: String?) -> [CGFloat] {
        switch speakerVariant(for: speakerId) {
        case 3:
            return [2, 2]
        case 4:
            return [4, 2]
        default:
            return []
        }
    }

    private func speakerVariant(for speakerId: String?) -> Int {
        guard let speakerId else { return 4 }
        if speakerId.hasSuffix("_1") || speakerId.lowercased().contains("1") { return 1 }
        if speakerId.hasSuffix("_2") || speakerId.lowercased().contains("2") { return 2 }
        if speakerId.hasSuffix("_3") || speakerId.lowercased().contains("3") { return 3 }
        return 4
    }
}

