import SwiftUI

/// The shared phosphor-green palette for Sector Zero's workspace chrome.
/// All view files draw from this single set so panels stay in tune with
/// each other; per-view color extensions are deliberately avoided.
extension Color {
    static let sectorWorkspace = Color(red: 0.015, green: 0.017, blue: 0.016)
    static let sectorSidebar = Color(red: 0.024, green: 0.028, blue: 0.026)
    static let sectorPanel = Color(red: 0.028, green: 0.033, blue: 0.030)
    static let sectorElevated = Color(red: 0.045, green: 0.052, blue: 0.047)
    static let sectorSelection = Color(red: 0.07, green: 0.12, blue: 0.085)
    static let sectorBorder = Color(red: 0.12, green: 0.20, blue: 0.15)
    static let sectorStrongBorder = Color(red: 0.19, green: 0.32, blue: 0.23)
    static let sectorText = Color(red: 0.74, green: 0.84, blue: 0.76)
    static let sectorHeading = Color(red: 0.64, green: 0.82, blue: 0.68)
    static let sectorMutedText = Color(red: 0.40, green: 0.51, blue: 0.43)
    static let sectorAccent = Color(red: 0.92, green: 0.74, blue: 0.34)

    /// Status semantics. Green reads as "live/ok", amber as "held/attention",
    /// red as "stopped in error" — shared by the run controls, the status
    /// chip, and the inspector so a machine's condition is one consistent hue.
    static let sectorRun = Color(red: 0.44, green: 0.86, blue: 0.55)
    static let sectorFault = Color(red: 0.91, green: 0.44, blue: 0.42)

    /// The single severity-to-hue mapping. Every view that shows machine
    /// condition goes through this so the same state never wears two colors.
    static func sectorStatus(_ severity: MachineCondition.Severity) -> Color {
        switch severity {
        case .live: .sectorRun
        case .ready: .sectorMutedText
        case .held: .sectorAccent
        case .fault: .sectorFault
        }
    }
}

extension Font {
    /// The monospaced terminal face used across the workspace chrome.
    static func sectorMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}

struct SectorCardModifier: ViewModifier {
    var cornerRadius: CGFloat = 10
    var fill = Color.sectorPanel

    func body(content: Content) -> some View {
        content
            .background(fill)
            .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke(Color.sectorBorder, lineWidth: 1)
                    .allowsHitTesting(false)
            }
    }
}

extension View {
    func sectorCard(cornerRadius: CGFloat = 10, fill: Color = .sectorPanel) -> some View {
        modifier(SectorCardModifier(cornerRadius: cornerRadius, fill: fill))
    }
}

struct SectorToolbarButtonStyle: ButtonStyle {
    @Environment(\.isEnabled) private var isEnabled

    var tint: Color?
    var isProminent = false

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.sectorMono(11, weight: .semibold))
            .tracking(0.7)
            .foregroundStyle(tint ?? Color.sectorText)
            .padding(.horizontal, 12)
            .frame(height: 32)
            .background {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .fill(backgroundColor(configuration: configuration))
            }
            .overlay {
                RoundedRectangle(cornerRadius: 7, style: .continuous)
                    .stroke(borderColor, lineWidth: 1)
            }
            .contentShape(Rectangle())
            .opacity(isEnabled ? (configuration.isPressed ? 0.72 : 1) : 0.38)
    }

    private func backgroundColor(configuration: Configuration) -> Color {
        if isProminent {
            return (tint ?? .sectorRun).opacity(configuration.isPressed ? 0.22 : 0.14)
        }
        return configuration.isPressed ? .sectorSelection : .sectorElevated
    }

    private var borderColor: Color {
        isProminent ? (tint ?? .sectorRun).opacity(0.55) : .sectorBorder
    }
}

struct SectorSectionLabel: View {
    let title: String
    var systemImage: String?

    var body: some View {
        HStack(spacing: 6) {
            if let systemImage {
                Image(systemName: systemImage)
                    .font(.system(size: 10, weight: .semibold))
            }
            Text(title)
                .font(.sectorMono(10, weight: .semibold))
                .tracking(1.3)
        }
        .foregroundStyle(Color.sectorMutedText)
        .accessibilityAddTraits(.isHeader)
    }
}
