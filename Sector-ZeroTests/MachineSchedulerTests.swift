import Testing
@testable import Sector_Zero

private final class SchedulerSpyDevice: ClockedDevice {
    var batches: [Int] = []
    var resetCount = 0

    var totalClocks: Int { batches.reduce(0, +) }

    func advance(by clocks: Int) {
        batches.append(clocks)
    }

    func reset() {
        resetCount += 1
        batches = []
    }
}

/// Milestone 40 — deterministic device clocking and bounded run slices.
struct MachineSchedulerTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithBytes(_ bytes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(bytes, at: resetVector)
        return machine
    }

    private func timerWakeMachine() -> Machine {
        let machine = Machine()
        // Reset vector -> 0050:0000. Main enables interrupts, idles in HLT,
        // proves execution resumed, then disables interrupts and halts for good.
        try! machine.bus.loadBytes([0xEA, 0x00, 0x00, 0x50, 0x00], at: resetVector)
        try! machine.bus.loadBytes([
            0xFB,                   // STI
            0xF4,                   // HLT until IRQ0
            0xBB, 0x34, 0x12,       // MOV BX,1234h
            0xFA,                   // CLI
            0xF4,                   // terminal HLT
        ], at: 0x00500)
        // IRQ0 vector 20h -> 0060:0000; acknowledge the PIC and return.
        try! machine.bus.loadBytes([0x00, 0x00, 0x60, 0x00], at: 0x20 * 4)
        try! machine.bus.loadBytes([0xB0, 0x20, 0xE6, 0x20, 0xCF], at: 0x00600)

        // XT-compatible master PIC with only IRQ0 unmasked.
        machine.bus.writeIOByte(0x11, at: 0x20)
        machine.bus.writeIOByte(0x20, at: 0x21)
        machine.bus.writeIOByte(0x00, at: 0x21)
        machine.bus.writeIOByte(0x01, at: 0x21)
        machine.bus.writeIOByte(0xFE, at: 0x21)
        // PIT channel 0, mode 2, reload 4096. The first timer edge is far
        // enough away that the CPU reaches HLT before IRQ0 becomes pending,
        // and the following period is long enough for the handler to IRET.
        machine.bus.writeIOByte(0x34, at: 0x43)
        machine.bus.writeIOByte(0x00, at: 0x40)
        machine.bus.writeIOByte(0x10, at: 0x40)
        return machine
    }

    @Test("Step reports elapsed clocks and advances each device by the same amount")
    func stepDrivesDevices() {
        let machine = machineWithBytes([0x90, 0xF4])
        let first = SchedulerSpyDevice()
        let second = SchedulerSpyDevice()
        machine.attachClockedDevice(first)
        machine.attachClockedDevice(second)

        #expect(machine.step() == 3)
        #expect(machine.step() == 2)
        #expect(first.batches == [3, 2])
        #expect(second.batches == [3, 2])
        #expect(first.totalClocks == Int(machine.cycleCount))
    }

    @Test("Run slice stops at HLT and publishes its final snapshot")
    func haltStopsSlice() {
        let machine = machineWithBytes([0x90, 0xF4, 0x90])

        let result = machine.runSlice(maxInstructions: 20)

        #expect(result.executedBoundaries == 2)
        #expect(result.elapsedClocks == 5)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot == machine.snapshot())
        #expect(result.snapshot.cpu.ip == 2)
    }

    @Test("Run slice obeys its instruction bound deterministically")
    func runBound() {
        let machine = machineWithBytes(Array(repeating: 0x90, count: 8))

        let result = machine.runSlice(maxInstructions: 3)

        #expect(result.executedBoundaries == 3)
        #expect(result.elapsedClocks == 9)
        #expect(result.stopReason == .instructionLimit)
        #expect(result.snapshot.cpu.ip == 3)
    }

    @Test("Pause request is sampled before every instruction boundary")
    func pauseLatency() {
        let machine = machineWithBytes(Array(repeating: 0x90, count: 8))
        var checks = 0

        let result = machine.runSlice(maxInstructions: 8) {
            checks += 1
            return checks == 3
        }

        #expect(result.executedBoundaries == 2)
        #expect(result.elapsedClocks == 6)
        #expect(result.stopReason == .paused)
        #expect(result.snapshot.cpu.ip == 2)
    }

    @Test("Reset clears the scheduler and resets attached devices")
    func reset() {
        let machine = machineWithBytes([0x90])
        let device = SchedulerSpyDevice()
        machine.attachClockedDevice(device)
        machine.step()

        machine.reset()

        #expect(machine.cycleCount == 0)
        #expect(machine.cpu.ip == 0)
        #expect(device.totalClocks == 0)
        #expect(device.resetCount == 1)
    }

    @Test("A wakeable interrupt advances devices while the CPU is halted")
    func haltedInterrupt() {
        let machine = machineWithBytes([0xF4])
        let device = SchedulerSpyDevice()
        machine.attachClockedDevice(device)
        machine.step()
        machine.requestNMI()

        let result = machine.runSlice(maxInstructions: 1)

        #expect(result.executedBoundaries == 1)
        #expect(result.elapsedClocks == 50)
        #expect(device.totalClocks == 52)
        #expect(!result.snapshot.cpu.halted)
    }

    @Test("Terminal halt policy leaves an enabled future timer interrupt pending in time")
    func terminalHaltPolicy() {
        let machine = timerWakeMachine()

        let result = machine.runSlice(maxInstructions: 50)

        #expect(result.stopReason == .halted)
        #expect(result.snapshot.cpu.halted)
        #expect(result.snapshot.cpu.bx == 0)
        #expect(result.elapsedClocks == 19)
    }

    @Test("Interruptible halt policy advances PIT time and wakes through IRQ0")
    func timerWakesHalt() {
        let machine = timerWakeMachine()

        let result = machine.runSlice(
            maxInstructions: 50,
            haltPolicy: .advanceToInterrupt
        )

        #expect(result.stopReason == .halted)
        #expect(result.snapshot.cpu.halted)
        #expect(result.snapshot.cpu.bx == 0x1234)
        #expect(result.snapshot.interruptController.inService == 0)
        #expect(result.elapsedClocks > 19)
    }

    @Test("Clock bound yields after a large halted-time jump for host pacing")
    func haltedIdleClockBound() {
        let machine = timerWakeMachine()

        let result = machine.runSlice(
            maxInstructions: 50,
            maxClocks: 20,
            haltPolicy: .advanceToInterrupt
        )

        #expect(result.stopReason == .instructionLimit)
        #expect(result.snapshot.cpu.halted)
        #expect(result.snapshot.cpu.bx == 0)
        #expect(result.elapsedClocks == 16_384)
    }

    @Test("A blocked WAIT ends a slice instead of spinning")
    func waitingStopsSlice() {
        let machine = machineWithBytes([0x9B, 0x90])
        machine.bus.coprocessorReady = false

        let result = machine.runSlice(maxInstructions: 100)

        #expect(result.executedBoundaries == 1)
        #expect(result.elapsedClocks == 4)
        #expect(result.stopReason == .waitingForCoprocessor)
    }
}
