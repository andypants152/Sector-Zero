import SwiftUI

/// The shared phosphor-green palette for Sector Zero's workspace chrome.
/// All view files draw from this single set so panels stay in tune with
/// each other; per-view color extensions are deliberately avoided.
extension Color {
    static let sectorWorkspace = Color(red: 0.015, green: 0.017, blue: 0.016)
    static let sectorSidebar = Color(red: 0.024, green: 0.028, blue: 0.026)
    static let sectorPanel = Color(red: 0.028, green: 0.033, blue: 0.030)
    static let sectorBorder = Color(red: 0.12, green: 0.20, blue: 0.15)
    static let sectorText = Color(red: 0.74, green: 0.84, blue: 0.76)
    static let sectorHeading = Color(red: 0.64, green: 0.82, blue: 0.68)
    static let sectorMutedText = Color(red: 0.40, green: 0.51, blue: 0.43)
    static let sectorAccent = Color(red: 0.92, green: 0.74, blue: 0.34)
}

extension Font {
    /// The monospaced terminal face used across the workspace chrome.
    static func sectorMono(_ size: CGFloat, weight: Font.Weight = .medium) -> Font {
        .system(size: size, weight: weight, design: .monospaced)
    }
}
