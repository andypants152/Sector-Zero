import SwiftUI

#if os(iOS)
import UIKit
#endif

/// One key on the emulated PC/XT keyboard, addressed by its XT scan-code
/// set 1 make code. Break codes are the make code with bit 7 set, formed
/// downstream by `SectorZeroWorkspace.pressXTKey`.
struct XTKey: Identifiable, Equatable {
    enum Kind {
        case momentary   // letters, digits, Space, Enter, arrows…
        case modifier    // Shift / Ctrl / Alt — latch one-shot, then lock
        case toggle      // Caps Lock — one make/break pair per tap
    }

    let label: String
    let makeCode: UInt8
    let kind: Kind
    let widthWeight: Double

    var id: String { "\(label)-\(makeCode)" }

    init(_ label: String, _ makeCode: UInt8, kind: Kind = .momentary, width: Double = 1) {
        self.label = label
        self.makeCode = makeCode
        self.kind = kind
        self.widthWeight = width
    }
}

enum XTKeyboardLayout {
    /// A PC/XT-flavoured layout: the keys an early-PC user needs, placed at the
    /// XT scan-code positions the guest BIOS understands. Cursor keys sit on the
    /// 83-key keypad positions, matching the hardware and `PCKeyMap`.
    static let rows: [[XTKey]] = [
        [
            XTKey("Esc", 0x01),
            XTKey("F1", 0x3B), XTKey("F2", 0x3C), XTKey("F3", 0x3D), XTKey("F4", 0x3E),
            XTKey("F5", 0x3F), XTKey("F6", 0x40), XTKey("F7", 0x41), XTKey("F8", 0x42),
            XTKey("F9", 0x43), XTKey("F10", 0x44),
        ],
        [
            XTKey("`", 0x29), XTKey("1", 0x02), XTKey("2", 0x03), XTKey("3", 0x04),
            XTKey("4", 0x05), XTKey("5", 0x06), XTKey("6", 0x07), XTKey("7", 0x08),
            XTKey("8", 0x09), XTKey("9", 0x0A), XTKey("0", 0x0B), XTKey("-", 0x0C),
            XTKey("=", 0x0D), XTKey("⌫", 0x0E, width: 1.6),
        ],
        [
            XTKey("Tab", 0x0F, width: 1.5), XTKey("Q", 0x10), XTKey("W", 0x11), XTKey("E", 0x12),
            XTKey("R", 0x13), XTKey("T", 0x14), XTKey("Y", 0x15), XTKey("U", 0x16),
            XTKey("I", 0x17), XTKey("O", 0x18), XTKey("P", 0x19), XTKey("[", 0x1A),
            XTKey("]", 0x1B), XTKey("\\", 0x2B),
        ],
        [
            XTKey("Caps", 0x3A, kind: .toggle, width: 1.7), XTKey("A", 0x1E), XTKey("S", 0x1F),
            XTKey("D", 0x20), XTKey("F", 0x21), XTKey("G", 0x22), XTKey("H", 0x23),
            XTKey("J", 0x24), XTKey("K", 0x25), XTKey("L", 0x26), XTKey(";", 0x27),
            XTKey("'", 0x28), XTKey("Enter", 0x1C, width: 1.9),
        ],
        [
            XTKey("Shift", 0x2A, kind: .modifier, width: 2.3), XTKey("Z", 0x2C), XTKey("X", 0x2D),
            XTKey("C", 0x2E), XTKey("V", 0x2F), XTKey("B", 0x30), XTKey("N", 0x31),
            XTKey("M", 0x32), XTKey(",", 0x33), XTKey(".", 0x34), XTKey("/", 0x35),
        ],
        [
            XTKey("Ctrl", 0x1D, kind: .modifier, width: 1.6),
            XTKey("Alt", 0x38, kind: .modifier, width: 1.6),
            XTKey("Space", 0x39, width: 5),
            XTKey("←", 0x4B), XTKey("↑", 0x48), XTKey("↓", 0x50), XTKey("→", 0x4D),
        ],
    ]

    static var allKeys: [XTKey] { rows.flatMap { $0 } }
}

/// Drives the on-screen keyboard's latch behaviour and emits XT make/break
/// transitions through an injected sink (the workspace in the app, a probe in
/// tests). Deliberately free of UIKit/AppKit so it unit-tests directly.
@MainActor
@Observable
final class OnScreenKeyboardController {
    enum Latch: Equatable { case off, oneShot, locked }

    private let send: (_ makeCode: UInt8, _ down: Bool) -> Void
    private(set) var latches: [UInt8: Latch] = [:]
    private(set) var capsEngaged = false
    private var heldModifiers: Set<UInt8> = []

    init(send: @escaping (_ makeCode: UInt8, _ down: Bool) -> Void) {
        self.send = send
    }

    func latch(for makeCode: UInt8) -> Latch { latches[makeCode] ?? .off }

    /// Cycles a modifier off → one-shot → locked → off. A one-shot releases
    /// itself after the next momentary key; a lock persists until tapped off.
    func tapModifier(_ key: XTKey) {
        let next: Latch
        switch latch(for: key.makeCode) {
        case .off: next = .oneShot
        case .oneShot: next = .locked
        case .locked: next = .off
        }
        latches[key.makeCode] = next
        if next == .off {
            releaseModifier(key.makeCode)
        }
    }

    /// Caps Lock toggles the guest with a single make/break pair, mirroring the
    /// macOS hardware path, and flips the on-screen indicator.
    func tapToggle(_ key: XTKey) {
        capsEngaged.toggle()
        send(key.makeCode, true)
        send(key.makeCode, false)
    }

    /// Momentary key touch-down: assert any active modifiers first (lowest scan
    /// code first, for determinism), then the key, so the guest reads e.g.
    /// Shift+A as an uppercase letter.
    func pressDown(_ key: XTKey) {
        for code in latches.keys.sorted() where latch(for: code) != .off && !heldModifiers.contains(code) {
            heldModifiers.insert(code)
            send(code, true)
        }
        send(key.makeCode, true)
    }

    /// Momentary key release: break the key, then release any one-shot
    /// modifiers (locks stay held for the next key).
    func pressUp(_ key: XTKey) {
        send(key.makeCode, false)
        for code in latches.keys.sorted() where latch(for: code) == .oneShot {
            latches[code] = .off
            releaseModifier(code)
        }
    }

    /// Releases every held modifier and clears latches — called when the
    /// keyboard is dismissed so nothing stays stuck down in the guest.
    func releaseAll() {
        for code in heldModifiers.sorted() {
            send(code, false)
        }
        heldModifiers.removeAll()
        latches.removeAll()
        capsEngaged = false
    }

    private func releaseModifier(_ makeCode: UInt8) {
        guard heldModifiers.remove(makeCode) != nil else { return }
        send(makeCode, false)
    }
}

/// A touch keyboard that posts XT scan codes straight to the machine, giving
/// iOS the input path the macOS `MachineKeyCaptureView` provides for hardware
/// keyboards.
struct MachineOnScreenKeyboardView: View {
    @State private var controller: OnScreenKeyboardController

    private let keyHeight: CGFloat = 44
    private let keySpacing: CGFloat = 5
    private let rowSpacing: CGFloat = 6

    init(workspace: SectorZeroWorkspace) {
        _controller = State(initialValue: OnScreenKeyboardController(send: { [weak workspace] makeCode, down in
            workspace?.pressXTKey(makeCode, down: down)
        }))
    }

    /// Injection point for previews and tests.
    init(controller: OnScreenKeyboardController) {
        _controller = State(initialValue: controller)
    }

    var body: some View {
        GeometryReader { proxy in
            VStack(spacing: rowSpacing) {
                ForEach(Array(XTKeyboardLayout.rows.enumerated()), id: \.offset) { _, rowKeys in
                    keyRow(rowKeys, availableWidth: proxy.size.width)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(height: keyboardHeight)
        .padding(8)
        .background(Color.sectorSidebar)
        .onDisappear { controller.releaseAll() }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("On-screen PC keyboard")
    }

    private var keyboardHeight: CGFloat {
        let count = CGFloat(XTKeyboardLayout.rows.count)
        return count * keyHeight + (count - 1) * rowSpacing
    }

    private func keyRow(_ keys: [XTKey], availableWidth: CGFloat) -> some View {
        let totalWeight = keys.reduce(0) { $0 + $1.widthWeight }
        let spacingTotal = keySpacing * CGFloat(max(keys.count - 1, 0))
        let unit = max(availableWidth - spacingTotal, 0) / max(totalWeight, 1)
        return HStack(spacing: keySpacing) {
            ForEach(keys) { key in
                KeyCap(key: key, controller: controller, width: unit * key.widthWeight, height: keyHeight)
            }
        }
    }
}

private struct KeyCap: View {
    let key: XTKey
    let controller: OnScreenKeyboardController
    let width: CGFloat
    let height: CGFloat
    @State private var isDown = false

    var body: some View {
        Text(key.label)
            .font(.sectorMono(key.label.count > 1 ? 11 : 15, weight: .semibold))
            .lineLimit(1)
            .minimumScaleFactor(0.6)
            .foregroundStyle(Color.sectorText)
            .frame(width: width, height: height)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous).fill(fill)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous).stroke(border, lineWidth: 1)
            )
            .contentShape(Rectangle())
            .gesture(gesture)
            .accessibilityLabel(key.label)
    }

    private var gesture: some Gesture {
        DragGesture(minimumDistance: 0)
            .onChanged { _ in
                guard key.kind == .momentary, !isDown else { return }
                isDown = true
                fireHaptic()
                controller.pressDown(key)
            }
            .onEnded { _ in
                switch key.kind {
                case .momentary:
                    if !isDown { controller.pressDown(key) }
                    isDown = false
                    controller.pressUp(key)
                case .modifier:
                    fireHaptic()
                    controller.tapModifier(key)
                case .toggle:
                    fireHaptic()
                    controller.tapToggle(key)
                }
            }
    }

    private func fireHaptic() {
        #if os(iOS)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private var fill: Color {
        switch key.kind {
        case .momentary:
            return isDown ? .sectorSelection : .sectorElevated
        case .modifier:
            switch controller.latch(for: key.makeCode) {
            case .off: return .sectorElevated
            case .oneShot: return .sectorSelection
            case .locked: return Color.sectorRun.opacity(0.22)
            }
        case .toggle:
            return controller.capsEngaged ? Color.sectorRun.opacity(0.22) : .sectorElevated
        }
    }

    private var border: Color {
        let engaged: Bool
        switch key.kind {
        case .momentary: engaged = isDown
        case .modifier: engaged = controller.latch(for: key.makeCode) != .off
        case .toggle: engaged = controller.capsEngaged
        }
        return engaged ? Color.sectorRun.opacity(0.6) : .sectorBorder
    }
}

#Preview {
    MachineOnScreenKeyboardView(workspace: SectorZeroWorkspace())
        .frame(width: 420)
        .background(Color.sectorWorkspace)
}
