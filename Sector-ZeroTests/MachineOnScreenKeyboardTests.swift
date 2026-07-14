import Foundation
import Testing
@testable import Sector_Zero

@MainActor
struct MachineOnScreenKeyboardTests {

    // MARK: - Layout / scan codes

    @Test("Layout keys carry their XT scan-code set 1 make codes")
    func layoutMakeCodes() {
        let byLabel = Dictionary(
            XTKeyboardLayout.allKeys.map { ($0.label, $0.makeCode) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(byLabel["Esc"] == 0x01)
        #expect(byLabel["A"] == 0x1E)
        #expect(byLabel["Enter"] == 0x1C)
        #expect(byLabel["Space"] == 0x39)
        #expect(byLabel["⌫"] == 0x0E)
        #expect(byLabel["Tab"] == 0x0F)
        #expect(byLabel["F1"] == 0x3B)
        #expect(byLabel["F10"] == 0x44)
        #expect(byLabel["Shift"] == 0x2A)
        #expect(byLabel["Ctrl"] == 0x1D)
        #expect(byLabel["Alt"] == 0x38)
        #expect(byLabel["Caps"] == 0x3A)
        #expect(byLabel["←"] == 0x4B)
        #expect(byLabel["↑"] == 0x48)
        #expect(byLabel["↓"] == 0x50)
        #expect(byLabel["→"] == 0x4D)
    }

    @Test("Every layout key uses a 7-bit make code so break codes stay distinct")
    func makeCodesAreSevenBit() {
        for key in XTKeyboardLayout.allKeys {
            #expect(key.makeCode < 0x80)
        }
    }

    @Test("Modifier and toggle kinds are assigned to the right keys")
    func keyKinds() {
        let byLabel = Dictionary(
            XTKeyboardLayout.allKeys.map { ($0.label, $0.kind) },
            uniquingKeysWith: { first, _ in first }
        )
        #expect(byLabel["Shift"] == .modifier)
        #expect(byLabel["Ctrl"] == .modifier)
        #expect(byLabel["Alt"] == .modifier)
        #expect(byLabel["Caps"] == .toggle)
        #expect(byLabel["A"] == .momentary)
        #expect(byLabel["Space"] == .momentary)
    }

    // MARK: - Modifier state machine

    private func probe() -> (OnScreenKeyboardController, () -> [(code: UInt8, down: Bool)]) {
        var events: [(code: UInt8, down: Bool)] = []
        let controller = OnScreenKeyboardController { code, down in
            events.append((code, down))
        }
        return (controller, { events })
    }

    private let shift = XTKey("Shift", 0x2A, kind: .modifier)
    private let ctrl = XTKey("Ctrl", 0x1D, kind: .modifier)
    private let alt = XTKey("Alt", 0x38, kind: .modifier)
    private let caps = XTKey("Caps", 0x3A, kind: .toggle)
    private let keyA = XTKey("A", 0x1E)
    private let keyB = XTKey("B", 0x30)

    @Test("A one-shot modifier wraps the next key, then releases itself")
    func oneShotWrapsNextKey() {
        let (controller, events) = probe()

        controller.tapModifier(shift)   // off → one-shot (make deferred)
        controller.pressDown(keyA)
        controller.pressUp(keyA)

        #expect(events().map(\.code) == [0x2A, 0x1E, 0x1E, 0x2A])
        #expect(events().map(\.down) == [true, true, false, false])
        #expect(controller.latch(for: 0x2A) == .off)
    }

    @Test("Tapping a modifier cycles off → one-shot → locked → off")
    func modifierLatchCycles() {
        let (controller, _) = probe()

        #expect(controller.latch(for: 0x38) == .off)
        controller.tapModifier(alt)
        #expect(controller.latch(for: 0x38) == .oneShot)
        controller.tapModifier(alt)
        #expect(controller.latch(for: 0x38) == .locked)
        controller.tapModifier(alt)
        #expect(controller.latch(for: 0x38) == .off)
    }

    @Test("A locked modifier stays down across several keys until tapped off")
    func lockedModifierPersists() {
        let (controller, events) = probe()

        controller.tapModifier(ctrl)    // one-shot
        controller.tapModifier(ctrl)    // locked
        controller.pressDown(keyA); controller.pressUp(keyA)
        controller.pressDown(keyB); controller.pressUp(keyB)
        controller.tapModifier(ctrl)    // locked → off

        #expect(events().map(\.code) == [0x1D, 0x1E, 0x1E, 0x30, 0x30, 0x1D])
        #expect(events().map(\.down) == [true, true, false, true, false, false])
    }

    @Test("Caps Lock sends a single make/break pair and flips the indicator")
    func capsTogglePair() {
        let (controller, events) = probe()

        #expect(controller.capsEngaged == false)
        controller.tapToggle(caps)
        #expect(controller.capsEngaged == true)
        #expect(events().map(\.code) == [0x3A, 0x3A])
        #expect(events().map(\.down) == [true, false])

        controller.tapToggle(caps)
        #expect(controller.capsEngaged == false)
    }

    @Test("Dismissing the keyboard breaks a held lock so nothing sticks in the guest")
    func releaseAllBreaksHeldLock() {
        let (controller, events) = probe()

        controller.tapModifier(shift)   // one-shot
        controller.tapModifier(shift)   // locked
        controller.pressDown(keyA); controller.pressUp(keyA)  // shift now held down
        controller.releaseAll()

        #expect(events().last?.code == 0x2A)
        #expect(events().last?.down == false)
        #expect(controller.latch(for: 0x2A) == .off)
    }

    // MARK: - Workspace delivery

    private func idleWorkspace() -> SectorZeroWorkspace {
        let machine = Machine()
        let image = Data([0x90] + Array(repeating: UInt8(0xF4), count: 15))
        try! machine.loadSystemROM(image)
        return SectorZeroWorkspace(machine: machine)
    }

    @Test("pressXTKey posts make then break codes that reach the machine while idle")
    func pressXTKeyReachesMachine() {
        let workspace = idleWorkspace()

        workspace.pressXTKey(0x1E, down: true)   // A make
        #expect(workspace.pressedScanCodes == [0x1E])
        #expect(workspace.machineSnapshot.peripheralInterface.latchedScanCode == 0x1E)

        workspace.pressXTKey(0x1E, down: false)  // A break
        #expect(workspace.pressedScanCodes.isEmpty)
        #expect(workspace.machineSnapshot.peripheralInterface.pendingScanCodeCount == 1)
    }

    @Test("A stray key-up posts nothing so filtered chords never leak breaks")
    func strayPressUpIgnored() {
        let workspace = idleWorkspace()

        workspace.pressXTKey(0x1E, down: false)

        #expect(workspace.pressedScanCodes.isEmpty)
        #expect(workspace.machineSnapshot.peripheralInterface.latchedScanCode == nil)
    }
}
