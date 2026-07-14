import Testing
import Foundation
@testable import Sector_Zero

struct PlatformClipboardTests {
    @Test("Copy places the string on the platform pasteboard")
    func copyPlacesStringOnPasteboard() {
        // Preserve whatever the developer/CI had on the clipboard.
        let previous = PlatformClipboard.currentString()
        defer {
            if let previous {
                PlatformClipboard.copy(previous)
            }
        }

        let unique = "SECTOR-ZERO-TRACE-\(UUID().uuidString)"
        PlatformClipboard.copy(unique)

        #expect(PlatformClipboard.currentString() == unique)
    }
}
