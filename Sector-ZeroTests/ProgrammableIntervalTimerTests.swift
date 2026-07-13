import Testing
@testable import Sector_Zero

/// Milestone 43 — deterministic 8253 timer, IRQ0, and speaker-gate behavior.
struct ProgrammableIntervalTimerTests {
    private func initializePIC(_ pic: ProgrammableInterruptController) {
        pic.writeByte(0x11, to: 0x20)
        pic.writeByte(0x20, to: 0x21)
        pic.writeByte(0x04, to: 0x21)
        pic.writeByte(0x01, to: 0x21)
        pic.writeByte(0x00, to: 0x21)
    }

    private func writeDivisor(_ divisor: UInt16, channelPort: UInt16, bus: EmulatorBus) {
        bus.writeIOByte(UInt8(truncatingIfNeeded: divisor), at: channelPort)
        bus.writeIOByte(UInt8(divisor >> 8), at: channelPort)
    }

    @Test("Mode 0 advances once per four CPU clocks and reaches terminal count")
    func mode0ClockConversion() {
        let machine = Machine()
        machine.bus.writeIOByte(0x30, at: 0x43) // Channel 0, low/high, mode 0.
        writeDivisor(3, channelPort: 0x40, bus: machine.bus)

        machine.intervalTimer.advance(by: 3)
        #expect(machine.intervalTimer.snapshot.channels[0].currentCount == 3)
        #expect(machine.intervalTimer.snapshot.cpuClockRemainder == 3)

        machine.intervalTimer.advance(by: 1)
        #expect(machine.intervalTimer.snapshot.channels[0].currentCount == 2)
        machine.intervalTimer.advance(by: 8)
        let channel = machine.intervalTimer.snapshot.channels[0]
        #expect(channel.currentCount == 0)
        #expect(channel.output)
        #expect(!channel.running)
        #expect(machine.interruptController.interruptRequest == 0x01)
    }

    @Test("A programmed zero divisor represents 65,536 and count latching is stable")
    func zeroDivisorAndLatch() {
        let machine = Machine()
        machine.bus.writeIOByte(0x70, at: 0x43) // Channel 1, low/high, mode 0.
        writeDivisor(0, channelPort: 0x41, bus: machine.bus)
        #expect(machine.intervalTimer.snapshot.channels[1].reloadValue == 65_536)

        machine.intervalTimer.advance(by: 4)
        machine.bus.writeIOByte(0x40, at: 0x43) // Latch channel 1.
        machine.intervalTimer.advance(by: 8)
        let low = machine.bus.readIOByte(at: 0x41)
        let high = machine.bus.readIOByte(at: 0x41)

        #expect(UInt16(low) | UInt16(high) << 8 == 0xFFFF)
        #expect(machine.intervalTimer.snapshot.channels[1].currentCount == 65_533)
    }

    @Test("Mode 3 raises periodic IRQ0 and PIC masking and EOI retain requests")
    func periodicIRQMaskAndEOI() {
        let machine = Machine()
        initializePIC(machine.interruptController)
        machine.bus.writeIOByte(0x36, at: 0x43) // Channel 0, low/high, mode 3.
        writeDivisor(4, channelPort: 0x40, bus: machine.bus)

        for _ in 0..<15 { machine.tick() }
        #expect(!machine.interruptController.hasPendingInterrupt)
        machine.tick()
        #expect(machine.interruptController.hasPendingInterrupt)
        #expect(machine.interruptController.acknowledge() == 0x20)
        #expect(machine.interruptController.inService == 0x01)

        // A later period is latched in IRR but cannot pass the same in-service
        // priority until software sends EOI.
        for _ in 0..<16 { machine.tick() }
        #expect(machine.interruptController.interruptRequest == 0x01)
        #expect(!machine.interruptController.hasPendingInterrupt)
        machine.bus.writeIOByte(0x20, at: 0x20)
        #expect(machine.interruptController.hasPendingInterrupt)

        machine.bus.writeIOByte(0x01, at: 0x21)
        #expect(!machine.interruptController.hasPendingInterrupt)
        machine.bus.writeIOByte(0x00, at: 0x21)
        #expect(machine.interruptController.hasPendingInterrupt)
    }

    @Test("Mode 2 emits a one-tick low pulse and repeats at the divisor")
    func rateGeneratorPulse() {
        let machine = Machine()
        initializePIC(machine.interruptController)
        machine.bus.writeIOByte(0x34, at: 0x43) // Channel 0, low/high, mode 2.
        writeDivisor(3, channelPort: 0x40, bus: machine.bus)

        machine.intervalTimer.advance(by: 12)
        #expect(!machine.intervalTimer.snapshot.channels[0].output)
        #expect(!machine.interruptController.hasPendingInterrupt)
        machine.intervalTimer.advance(by: 4)
        #expect(machine.intervalTimer.snapshot.channels[0].output)
        #expect(machine.interruptController.hasPendingInterrupt)
        #expect(machine.interruptController.acknowledge() == 0x20)
        machine.bus.writeIOByte(0x20, at: 0x20)

        machine.intervalTimer.advance(by: 8)
        #expect(!machine.intervalTimer.snapshot.channels[0].output)
        machine.intervalTimer.advance(by: 4)
        #expect(machine.interruptController.hasPendingInterrupt)
    }

    @Test("Channel 2 gate and speaker enable use conventional port 61h")
    func channel2SpeakerGate() {
        let machine = Machine()
        machine.bus.writeIOByte(0xB6, at: 0x43) // Channel 2, low/high, mode 3.
        writeDivisor(4, channelPort: 0x42, bus: machine.bus)

        machine.intervalTimer.advance(by: 32)
        #expect(machine.intervalTimer.snapshot.channels[2].currentCount == 4)
        #expect(machine.bus.readIOByte(at: 0x61) & 0x03 == 0)

        machine.bus.writeIOByte(0x03, at: 0x61)
        #expect(machine.bus.readIOByte(at: 0x61) & 0x03 == 0x03)
        #expect(machine.intervalTimer.snapshot.channel2SpeakerOutput)

        machine.intervalTimer.advance(by: 8)
        #expect(!machine.intervalTimer.snapshot.channels[2].output)
        #expect(!machine.intervalTimer.snapshot.channel2SpeakerOutput)
        machine.intervalTimer.advance(by: 8)
        #expect(machine.intervalTimer.snapshot.channel2SpeakerOutput)
    }

    @Test("Machine reset clears timer programming, clock remainder, and IRQ0")
    func resetAndSnapshot() {
        let machine = Machine()
        initializePIC(machine.interruptController)
        machine.bus.writeIOByte(0x30, at: 0x43)
        writeDivisor(1, channelPort: 0x40, bus: machine.bus)
        machine.intervalTimer.advance(by: 5)
        #expect(machine.interruptController.interruptRequest == 0x01)

        machine.reset()

        let snapshot = machine.snapshot().intervalTimer
        #expect(snapshot.cpuClockRemainder == 0)
        #expect(snapshot.channels[0].reloadValue == 65_536)
        #expect(!snapshot.channels[2].gate)
        #expect(machine.interruptController.interruptRequest == 0)
    }

    @Test("Irregular clock batches match one long deterministic advance")
    func longRunDeterminism() {
        let batched = Machine()
        let fragmented = Machine()
        for machine in [batched, fragmented] {
            initializePIC(machine.interruptController)
            machine.bus.writeIOByte(0x36, at: 0x43)
            writeDivisor(7, channelPort: 0x40, bus: machine.bus)
        }

        batched.intervalTimer.advance(by: 28_003)
        for clocks in [1, 2, 17, 4_096, 3, 8_191, 511, 15_182] {
            fragmented.intervalTimer.advance(by: clocks)
        }

        #expect(fragmented.intervalTimer.snapshot == batched.intervalTimer.snapshot)
        #expect(fragmented.interruptController.snapshot == batched.interruptController.snapshot)
    }
}
