import Testing
@testable import Sector_Zero

/// Milestone 42 — master 8259A interrupt-controller behavior and integration.
struct ProgrammableInterruptControllerTests {
    private func initialize(
        _ pic: ProgrammableInterruptController,
        vectorBase: UInt8 = 0x20,
        levelTriggered: Bool = false,
        autoEOI: Bool = false
    ) {
        pic.writeByte(levelTriggered ? 0x19 : 0x11, to: 0x20)
        pic.writeByte(vectorBase, to: 0x21)
        pic.writeByte(0x04, to: 0x21) // ICW3: slave would occupy IRQ2.
        pic.writeByte(autoEOI ? 0x03 : 0x01, to: 0x21)
    }

    private func installVector(
        _ vector: UInt8,
        offset: UInt16,
        segment: UInt16,
        in machine: Machine
    ) {
        let address = UInt32(vector) * 4
        machine.bus.writeWord(offset, at: address)
        machine.bus.writeWord(segment, at: address + 2)
    }

    @Test("ICWs initialize vector base and OCW1 mask through standard ports")
    func initializationAndMaskRegister() {
        let machine = Machine()
        let pic = machine.interruptController

        machine.bus.writeIOByte(0x11, at: 0x20)
        machine.bus.writeIOByte(0x23, at: 0x21)
        machine.bus.writeIOByte(0x04, at: 0x21)
        machine.bus.writeIOByte(0x01, at: 0x21)
        machine.bus.writeIOByte(0xFD, at: 0x21)

        #expect(pic.initialized)
        #expect(pic.vectorBase == 0x20)
        #expect(machine.bus.readIOByte(at: 0x21) == 0xFD)
        #expect(machine.snapshot().interruptController.interruptMask == 0xFD)

        machine.raiseIRQ(.timer)
        #expect(!pic.hasPendingInterrupt)
        machine.raiseIRQ(.keyboard)
        #expect(pic.hasPendingInterrupt)
        #expect(pic.acknowledge() == 0x21)
    }

    @Test("Fixed priority, ISR blocking, command reads, and EOI")
    func fixedPriorityAndEOI() {
        let pic = ProgrammableInterruptController()
        initialize(pic)
        pic.writeByte(0x00, to: 0x21)
        pic.raise(.serial1)
        pic.raise(.keyboard)

        #expect(pic.acknowledge() == 0x21)
        #expect(!pic.hasPendingInterrupt) // IRQ4 cannot preempt in-service IRQ1.

        pic.writeByte(0x0B, to: 0x20)
        #expect(pic.readByte(from: 0x20) == 0x02)
        pic.writeByte(0x0A, to: 0x20)
        #expect(pic.readByte(from: 0x20) == 0x10)

        pic.raise(.timer)
        #expect(pic.acknowledge() == 0x20) // Higher-priority IRQ0 can preempt.
        pic.writeByte(0x20, to: 0x20) // Non-specific EOI clears IRQ0 first.
        #expect(!pic.hasPendingInterrupt)
        pic.writeByte(0x61, to: 0x20) // Specific EOI for IRQ1.
        #expect(pic.acknowledge() == 0x24)
    }

    @Test("Edge and level modes follow distinct line-transition rules")
    func lineTransitions() {
        let edge = ProgrammableInterruptController()
        initialize(edge)
        edge.raise(.floppy)
        #expect(edge.acknowledge() == 0x26)
        edge.writeByte(0x20, to: 0x20)
        edge.raise(.floppy) // No new edge while the line remains asserted.
        #expect(!edge.hasPendingInterrupt)
        edge.lower(.floppy)
        edge.raise(.floppy)
        #expect(edge.hasPendingInterrupt)

        let level = ProgrammableInterruptController()
        initialize(level, levelTriggered: true)
        level.raise(.floppy)
        #expect(level.acknowledge() == 0x26)
        level.writeByte(0x20, to: 0x20)
        #expect(level.hasPendingInterrupt) // Still-high level reasserts after EOI.
        level.lower(.floppy)
        #expect(!level.hasPendingInterrupt)
    }

    @Test("IF gates PIC delivery and an unmasked IRQ wakes HLT")
    func ifInteractionAndHaltWake() {
        let machine = Machine()
        try! machine.bus.loadBytes([0xF4], at: 0xFFFF0)
        installVector(0x20, offset: 0x0100, segment: 0x2000, in: machine)
        initialize(machine.interruptController)
        machine.bus.writeIOByte(0x01, at: 0x21) // Initially mask IRQ0.
        _ = machine.cpu.execute(.setFlag(.interruptEnable))

        machine.step()
        #expect(machine.cpu.halted)
        machine.raiseIRQ(.timer)
        machine.step()
        #expect(machine.cpu.halted)

        machine.bus.writeIOByte(0x00, at: 0x21)
        machine.step()
        #expect(!machine.cpu.halted)
        #expect(machine.cpu.cs == 0x2000)
        #expect(machine.cpu.ip == 0x0100)
        #expect(machine.interruptController.inService == 0x01)
    }

    @Test("Pending IRQ waits while IF is clear")
    func interruptEnableGate() {
        let machine = Machine()
        try! machine.bus.loadBytes([0x90, 0x90], at: 0xFFFF0)
        installVector(0x20, offset: 0, segment: 0x3000, in: machine)
        initialize(machine.interruptController)
        machine.raiseIRQ(.timer)

        machine.step()
        #expect(machine.cpu.cs == 0xFFFF)
        #expect(machine.cpu.ip == 1)
        #expect(machine.interruptController.interruptRequest == 0x01)

        _ = machine.cpu.execute(.setFlag(.interruptEnable))
        machine.step()
        #expect(machine.cpu.cs == 0x3000)
        #expect(machine.cpu.ip == 0)
    }
}
