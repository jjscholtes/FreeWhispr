import SwiftUI

struct SpeakerBadgeView: View {
    let label: String
    let styleIndex: Int

    var body: some View {
        Text(label)
            .font(.system(size: 11, weight: .semibold, design: .monospaced))
            .foregroundStyle(styleIndex == 1 ? Color.white : DS.ColorToken.fgPrimary)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(backgroundShape)
            .overlay(borderOverlay)
            .frame(minWidth: 44)
    }

    @ViewBuilder
    private var backgroundShape: some View {
        if styleIndex == 1 {
            Capsule().fill(DS.ColorToken.fgPrimary)
        } else {
            Capsule().fill(Color.white)
        }
    }

    @ViewBuilder
    private var borderOverlay: some View {
        switch styleIndex {
        case 1:
            Capsule().stroke(DS.ColorToken.fgPrimary, lineWidth: 1)
        case 2:
            Capsule().stroke(DS.ColorToken.fgPrimary, lineWidth: 1)
        case 3:
            ZStack {
                Capsule().stroke(DS.ColorToken.fgPrimary, lineWidth: 1)
                Capsule().inset(by: 3).stroke(DS.ColorToken.fgPrimary, lineWidth: 1)
            }
        default:
            Capsule().stroke(DS.ColorToken.fgPrimary, style: StrokeStyle(lineWidth: 1, dash: [3, 2]))
        }
    }
}

