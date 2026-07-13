#if os(macOS)
import SwiftUI
import AppKit

/// Captures raw hardware key events for the emulated machine. Clicking the
/// CRT focuses it; focus loss releases every held key so the guest never
/// sees a key stuck down.
struct MachineKeyCaptureView: NSViewRepresentable {
    let workspace: SectorZeroWorkspace

    func makeNSView(context: Context) -> KeyCaptureNSView {
        let view = KeyCaptureNSView()
        view.workspace = workspace
        return view
    }

    func updateNSView(_ nsView: KeyCaptureNSView, context: Context) {
        nsView.workspace = workspace
    }

    final class KeyCaptureNSView: NSView {
        weak var workspace: SectorZeroWorkspace?
        private var downModifierKeyCodes: Set<UInt16> = []

        override var acceptsFirstResponder: Bool { true }

        override func mouseDown(with event: NSEvent) {
            window?.makeFirstResponder(self)
        }

        override func keyDown(with event: NSEvent) {
            // Command chords are host shortcuts, never guest keystrokes.
            guard !event.modifierFlags.contains(.command) else { return }
            workspace?.handleHostKey(down: true, keyCode: event.keyCode, isRepeat: event.isARepeat)
        }

        override func keyUp(with event: NSEvent) {
            workspace?.handleHostKey(down: false, keyCode: event.keyCode)
        }

        override func flagsChanged(with event: NSEvent) {
            let keyCode = event.keyCode
            // Caps Lock reports state toggles rather than press/release;
            // forward one make/break pair so the guest toggles exactly once.
            if keyCode == 0x39 {
                workspace?.handleHostKey(down: true, keyCode: keyCode)
                workspace?.handleHostKey(down: false, keyCode: keyCode)
                return
            }
            if downModifierKeyCodes.remove(keyCode) == nil {
                downModifierKeyCodes.insert(keyCode)
                workspace?.handleHostKey(down: true, keyCode: keyCode)
            } else {
                workspace?.handleHostKey(down: false, keyCode: keyCode)
            }
        }

        override func resignFirstResponder() -> Bool {
            downModifierKeyCodes.removeAll()
            workspace?.releaseAllHostKeys()
            return super.resignFirstResponder()
        }
    }
}
#endif
