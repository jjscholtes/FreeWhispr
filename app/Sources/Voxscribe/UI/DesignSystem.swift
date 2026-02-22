import SwiftUI

enum DS {
    enum ColorToken {
        static let bgApp = Color.white
        static let bgPanel = Color(red: 0.965, green: 0.965, blue: 0.957)
        static let bgPanelAlt = Color(red: 0.98, green: 0.98, blue: 0.973)
        static let fgPrimary = Color(red: 0.067, green: 0.067, blue: 0.067)
        static let fgSecondary = Color(red: 0.38, green: 0.38, blue: 0.38)
        static let fgTertiary = Color(red: 0.55, green: 0.55, blue: 0.55)
        static let borderSoft = Color(red: 0.867, green: 0.867, blue: 0.867)
        static let borderStrong = Color(red: 0.741, green: 0.741, blue: 0.741)
    }

    enum Radius {
        static let sm: CGFloat = 8
        static let md: CGFloat = 12
        static let lg: CGFloat = 18
    }
}

struct CapsLabel: View {
    let text: String

    var body: some View {
        Text(text.uppercased())
            .font(.system(size: 11, weight: .semibold))
            .tracking(0.8)
            .foregroundStyle(DS.ColorToken.fgSecondary)
    }
}

struct BannerView: View {
    let text: String
    let isError: Bool
    var technicalDetails: String? = nil
    var onDismiss: () -> Void
    @State private var showDetails = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Image(systemName: isError ? "exclamationmark.triangle" : "checkmark.circle")
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                Text(text)
                    .font(.system(size: 13))
                    .foregroundStyle(DS.ColorToken.fgPrimary)
                Spacer()
                Button("Dismiss", action: onDismiss)
                    .buttonStyle(.plain)
                    .foregroundStyle(DS.ColorToken.fgSecondary)
            }
            if let technicalDetails, isError {
                DisclosureGroup(isExpanded: $showDetails) {
                    ScrollView {
                        Text(technicalDetails)
                            .font(.system(size: 11, design: .monospaced))
                            .foregroundStyle(DS.ColorToken.fgSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .textSelection(.enabled)
                    }
                    .frame(maxHeight: 120)
                } label: {
                    Text("Technical Details")
                        .font(.system(size: 12, weight: .medium))
                        .foregroundStyle(DS.ColorToken.fgSecondary)
                }
            }
        }
        .padding(12)
        .background(DS.ColorToken.bgPanel)
        .overlay(RoundedRectangle(cornerRadius: DS.Radius.md).stroke(DS.ColorToken.borderSoft, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: DS.Radius.md))
    }
}
