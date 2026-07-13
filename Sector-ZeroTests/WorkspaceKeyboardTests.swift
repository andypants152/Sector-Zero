import Foundation
import Testing
@testable import Sector_Zero

@MainActor
struct WorkspaceKeyboardTests {
    /// NOP + HLT firmware keeps the machine quietly steppable; these tests
    /// exercise the idle input path, so the machine never runs.
    private func makeWorkspace() -> SectorZeroWorkspace {
        let machine = Machine()
        let image = Data([0x90] + Array(repeating: UInt8(0xF4), count: 15))
        try! machine.loadSystemROM(image)
        return SectorZeroWorkspace(machine: machine)
    }

    @Test("A mapped key press translates to its XT make code and reaches the machine while idle")
    func keyDownTranslatesAndDelivers() {
        let workspace = makeWorkspace()

        workspace.handleHostKey(down: true, keyCode: 0x00) // macOS 'A'

        #expect(workspace.pressedScanCodes == [0x1E])
        #expect(workspace.machineSnapshot.peripheralInterface.latchedScanCode == 0x1E)
    }

    @Test("Releasing a key posts the matching break code")
    func keyUpPostsBreakCode() {
        let workspace = makeWorkspace()

        workspace.handleHostKey(down: true, keyCode: 0x00)
        workspace.handleHostKey(down: false, keyCode: 0x00)

        #expect(workspace.pressedScanCodes.isEmpty)
        #expect(workspace.machineSnapshot.peripheralInterface.latchedScanCode == 0x1E)
        #expect(workspace.machineSnapshot.peripheralInterface.pendingScanCodeCount == 1)
    }

    @Test("Typematic repeats forward additional make codes like the XT keyboard")
    func repeatForwardsMakeCodes() {
        let workspace = makeWorkspace()

        workspace.handleHostKey(down: true, keyCode: 0x31) // Space
        workspace.handleHostKey(down: true, keyCode: 0x31, isRepeat: true)
        workspace.handleHostKey(down: true, keyCode: 0x31, isRepeat: true)

        #expect(workspace.pressedScanCodes == [0x39])
        #expect(workspace.machineSnapshot.peripheralInterface.latchedScanCode == 0x39)
        #expect(workspace.machineSnapshot.peripheralInterface.pendingScanCodeCount == 2)
    }

    @Test("A key-up without a tracked key-down posts nothing — filtered chords must not leak breaks")
    func strayKeyUpIsIgnored() {
        let workspace = makeWorkspace()

        workspace.handleHostKey(down: false, keyCode: 0x0F) // 'r' released after a ⌘R chord

        #expect(workspace.pressedScanCodes.isEmpty)
        #expect(workspace.machineSnapshot.peripheralInterface.latchedScanCode == nil)
        #expect(workspace.machineSnapshot.peripheralInterface.pendingScanCodeCount == 0)
    }

    @Test("Unmapped host keys are ignored")
    func unmappedKeysAreIgnored() {
        let workspace = makeWorkspace()

        workspace.handleHostKey(down: true, keyCode: 0x37) // Command has no XT equivalent.

        #expect(workspace.pressedScanCodes.isEmpty)
        #expect(workspace.machineSnapshot.peripheralInterface.latchedScanCode == nil)
    }

    @Test("Focus loss releases every held key with deterministic break-code order")
    func focusLossReleasesAllKeys() {
        let workspace = makeWorkspace()

        workspace.handleHostKey(down: true, keyCode: 0x00) // A → 0x1E
        workspace.handleHostKey(down: true, keyCode: 0x38) // Shift → 0x2A
        workspace.releaseAllHostKeys()

        #expect(workspace.pressedScanCodes.isEmpty)
        // Latch holds the first make; the queue holds the second make plus
        // both break codes, lowest scan code first.
        let ppi = workspace.machineSnapshot.peripheralInterface
        #expect(ppi.latchedScanCode == 0x1E)
        #expect(ppi.pendingScanCodeCount == 3)
    }

    @Test("Modifier and control keys translate to their XT positions")
    func modifierAndControlTranslation() {
        #expect(PCKeyMap.makeCode(forMacKeyCode: 0x24) == 0x1C) // Return
        #expect(PCKeyMap.makeCode(forMacKeyCode: 0x35) == 0x01) // Escape
        #expect(PCKeyMap.makeCode(forMacKeyCode: 0x33) == 0x0E) // Delete → Backspace
        #expect(PCKeyMap.makeCode(forMacKeyCode: 0x38) == 0x2A) // Left Shift
        #expect(PCKeyMap.makeCode(forMacKeyCode: 0x3C) == 0x36) // Right Shift
        #expect(PCKeyMap.makeCode(forMacKeyCode: 0x3B) == 0x1D) // Control
        #expect(PCKeyMap.makeCode(forMacKeyCode: 0x3A) == 0x38) // Option → Alt
        #expect(PCKeyMap.makeCode(forMacKeyCode: 0x7E) == 0x48) // Up → keypad 8 (83-key XT)
        #expect(PCKeyMap.makeCode(forMacKeyCode: 0x7B) == 0x4B) // Left → keypad 4
        #expect(PCKeyMap.makeCode(forMacKeyCode: 0x7A) == 0x3B) // F1
    }
}
