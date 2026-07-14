import Foundation

#if os(macOS)
import AppKit
#else
import UIKit
#endif

/// A single seam for copying text to the system pasteboard so cross-platform
/// views don't each carry their own `#if os(...)` clipboard branch.
enum PlatformClipboard {
    static func copy(_ string: String) {
        #if os(macOS)
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(string, forType: .string)
        #else
        UIPasteboard.general.string = string
        #endif
    }

    /// The current pasteboard text, if any. Primarily a test/read-back seam.
    static func currentString() -> String? {
        #if os(macOS)
        NSPasteboard.general.string(forType: .string)
        #else
        UIPasteboard.general.string
        #endif
    }
}
