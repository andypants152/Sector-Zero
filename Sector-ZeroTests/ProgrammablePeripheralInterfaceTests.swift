import Foundation
import Testing
@testable import Sector_Zero

/// Milestone 45 — 8255 PPI subset: XT keyboard scan-code latch, acknowledge
/// handshake, IRQ1 routing, speaker-bit delegation, and the host input inbox.
struct ProgrammablePeripheralInterfaceTests {
    private func initializePIC(_ pic: ProgrammableInterruptController) {
        pic.writeByte(0x11, to: 0x20)
        pic.writeByte(0x20, to: 0x21)
        pic.writeByte(0x04, to: 0x21)
        pic.writeByte(0x01, to: 0x21)
        pic.writeByte(0x00, to: 0x21)
    }

    @Test("A received make code latches at port 60h and raises IRQ1 without being cleared by reads")
    func makeCodeLatchAndIRQ() {
        let machine = Machine()
        initializePIC(machine.interruptController)

        machine.bus.peripheralInterface.receiveScanCode(0x1E)

        #expect(machine.bus.readIOByte(at: 0x60) == 0x1E)
        #expect(machine.bus.readIOByte(at: 0x60) == 0x1E)
        #expect(machine.interruptController.interruptRequest == 0x02)
        #expect(machine.bus.peripheralInterface.snapshot.pendingScanCodeCount == 0)
    }

    @Test("The port 61h bit-7 pulse acknowledges the latch and delivers the next queued code")
    func acknowledgeHandshake() {
        let machine = Machine()
        initializePIC(machine.interruptController)
        let ppi = machine.bus.peripheralInterface

        ppi.receiveScanCode(0x1E)
        ppi.receiveScanCode(0x9E)
        #expect(machine.bus.readIOByte(at: 0x60) == 0x1E)
        #expect(machine.interruptController.acknowledge() == 0x21)
        machine.interruptController.writeByte(0x20, to: 0x20) // Non-specific EOI.

        // The XT BIOS idiom: read port B, momentarily set bit 7, restore.
        let portB = machine.bus.readIOByte(at: 0x61)
        machine.bus.writeIOByte(portB | 0x80, at: 0x61)
        #expect(machine.bus.readIOByte(at: 0x60) == 0)
        #expect(machine.interruptController.snapshot.assertedLines & 0x02 == 0)

        machine.bus.writeIOByte(portB & 0x7F, at: 0x61)
        #expect(machine.bus.readIOByte(at: 0x60) == 0x9E)
        #expect(machine.interruptController.interruptRequest & 0x02 == 0x02)
    }

    @Test("Lowering the keyboard clock enable holds scan codes until re-enabled")
    func clockInhibit() {
        let machine = Machine()
        initializePIC(machine.interruptController)
        let ppi = machine.bus.peripheralInterface

        machine.bus.writeIOByte(0x00, at: 0x61) // PB6 low: keyboard clock disabled.
        ppi.receiveScanCode(0x10)

        #expect(machine.bus.readIOByte(at: 0x60) == 0)
        #expect(machine.interruptController.interruptRequest == 0)
        #expect(ppi.snapshot.pendingScanCodeCount == 1)

        machine.bus.writeIOByte(0x40, at: 0x61) // Clock re-enabled.
        #expect(machine.bus.readIOByte(at: 0x60) == 0x10)
        #expect(machine.interruptController.interruptRequest == 0x02)
    }

    @Test("The scan-code queue keeps order, drops overflow, and counts overruns")
    func queueOrderingAndOverflow() {
        let machine = Machine()
        let ppi = machine.bus.peripheralInterface

        // One latches immediately; capacity more queue behind it.
        let accepted = 1 + ProgrammablePeripheralInterface.scanCodeQueueCapacity
        for code in 1...accepted {
            ppi.receiveScanCode(UInt8(code))
        }
        ppi.receiveScanCode(0x55)

        #expect(ppi.snapshot.overrunCount == 1)
        #expect(ppi.snapshot.pendingScanCodeCount == ProgrammablePeripheralInterface.scanCodeQueueCapacity)

        var delivered: [UInt8] = []
        for _ in 0..<accepted {
            delivered.append(machine.bus.readIOByte(at: 0x60))
            machine.bus.writeIOByte(0xC0, at: 0x61)
            machine.bus.writeIOByte(0x40, at: 0x61)
        }
        #expect(delivered == (1...accepted).map(UInt8.init))
        #expect(machine.bus.readIOByte(at: 0x60) == 0)
    }

    @Test("Port B speaker bits reach the PIT and port C mirrors timer-2 output")
    func speakerDelegationAndPortC() {
        let machine = Machine()
        machine.bus.writeIOByte(0xB6, at: 0x43) // Channel 2, low/high, mode 3.
        machine.bus.writeIOByte(4, at: 0x42)
        machine.bus.writeIOByte(0, at: 0x42)

        machine.bus.writeIOByte(0x43, at: 0x61) // Gate + speaker, keyboard clock kept high.
        #expect(machine.bus.readIOByte(at: 0x61) == 0x43)
        #expect(machine.intervalTimer.snapshot.channel2SpeakerOutput)
        #expect(machine.bus.readIOByte(at: 0x62) & 0x20 == 0x20)

        machine.intervalTimer.advance(by: 8) // Half of the divisor-4 square wave.
        #expect(!machine.intervalTimer.snapshot.channel2SpeakerOutput)
        #expect(machine.bus.readIOByte(at: 0x62) & 0x20 == 0)
    }

    @Test("The control register stores the XT configuration and reset restores power-on state")
    func controlAndReset() {
        let machine = Machine()
        initializePIC(machine.interruptController)
        let ppi = machine.bus.peripheralInterface

        machine.bus.writeIOByte(0x99, at: 0x63)
        #expect(machine.bus.readIOByte(at: 0x63) == 0x99)

        ppi.receiveScanCode(0x1E)
        ppi.receiveScanCode(0x1F)
        machine.bus.writeIOByte(0x00, at: 0x61)
        machine.reset()

        let snapshot = ppi.snapshot
        #expect(snapshot.latchedScanCode == nil)
        #expect(snapshot.pendingScanCodeCount == 0)
        #expect(snapshot.overrunCount == 0)
        #expect(snapshot.portBRegister == 0x40)
        #expect(snapshot.keyboardClockEnabled)
        #expect(machine.interruptController.interruptRequest == 0)
    }

    @Test("A masked IRQ1 stays requested but undeliverable until unmasked")
    func maskInteraction() {
        let machine = Machine()
        initializePIC(machine.interruptController)
        machine.interruptController.writeByte(0x02, to: 0x21) // Mask IRQ1.

        machine.bus.peripheralInterface.receiveScanCode(0x1E)
        #expect(machine.interruptController.interruptRequest & 0x02 == 0x02)
        #expect(!machine.interruptController.hasPendingInterrupt)

        machine.interruptController.writeByte(0x00, to: 0x21)
        #expect(machine.interruptController.hasPendingInterrupt)
        #expect(machine.interruptController.acknowledge() == 0x21)
    }

    @Test("A code latched before PIC initialization needs the POST clear pulse — authentic XT behavior")
    func staleLatchBeforePICInitialization() {
        let machine = Machine()
        let ppi = machine.bus.peripheralInterface

        // Typed before firmware ran: the edge is lost when the PIC is
        // initialized afterwards, and the occupied latch blocks new edges.
        ppi.receiveScanCode(0x1E)
        ppi.receiveScanCode(0x1F)
        initializePIC(machine.interruptController)
        #expect(machine.interruptController.interruptRequest == 0)

        // The XT BIOS's POST keyboard-clear pulse discards the stale code and
        // lets the queued one deliver with a fresh edge.
        machine.bus.writeIOByte(0xC0, at: 0x61)
        machine.bus.writeIOByte(0x40, at: 0x61)
        #expect(machine.bus.readIOByte(at: 0x60) == 0x1F)
        #expect(machine.interruptController.interruptRequest == 0x02)
    }

    @Test("Scan codes posted from the host thread drain at instruction boundaries")
    func hostInboxDrain() throws {
        let machine = Machine()
        try machine.bus.loadBytes([0x90, 0xF4], at: 0xFFFF0)

        machine.postScanCode(0x1E)
        #expect(machine.bus.peripheralInterface.snapshot.latchedScanCode == nil)

        machine.step()
        #expect(machine.bus.peripheralInterface.snapshot.latchedScanCode == 0x1E)
    }

    @Test("A keystroke wakes a halted machine and the IRQ1 handler completes the XT handshake")
    func endToEndKeyboardInterrupt() throws {
        let machine = Machine()
        initializePIC(machine.interruptController)

        // IVT entry for vector 0x21 (PIC base 0x20 + IRQ1) → 0060:0000.
        try machine.bus.loadBytes([0x00, 0x00, 0x60, 0x00], at: 0x21 * 4)
        // Handler: read the scan code, store it at 0000:0700, pulse the
        // keyboard-clear bit, EOI the PIC, and return.
        try machine.bus.loadBytes([
            0x31, 0xC0,             // XOR AX, AX
            0x8E, 0xD8,             // MOV DS, AX
            0xE4, 0x60,             // IN AL, 60h
            0xA2, 0x00, 0x07,       // MOV [0700h], AL
            0xE4, 0x61,             // IN AL, 61h
            0x0C, 0x80,             // OR AL, 80h
            0xE6, 0x61,             // OUT 61h, AL
            0x24, 0x7F,             // AND AL, 7Fh
            0xE6, 0x61,             // OUT 61h, AL
            0xB0, 0x20,             // MOV AL, 20h
            0xE6, 0x20,             // OUT 20h, AL (EOI)
            0xCF,                   // IRET
        ], at: 0x00600)
        // Main program: enable interrupts and halt twice; the second HLT is
        // where the machine rests after the handler returns.
        try machine.bus.loadBytes([0xFB, 0xF4, 0xF4], at: 0x00500)
        try machine.bus.loadBytes([0xEA, 0x00, 0x00, 0x50, 0x00], at: 0xFFFF0)

        var slice = machine.runSlice(maxInstructions: 16)
        #expect(slice.stopReason == .halted)

        machine.postScanCode(0x1E)
        slice = machine.runSlice(maxInstructions: 64)

        #expect(slice.stopReason == .halted)
        #expect(machine.bus.readByte(at: 0x00700) == 0x1E)
        #expect(machine.bus.readIOByte(at: 0x60) == 0)
        #expect(machine.interruptController.snapshot.inService == 0)
        #expect(machine.snapshot().peripheralInterface.latchedScanCode == nil)
    }
}
