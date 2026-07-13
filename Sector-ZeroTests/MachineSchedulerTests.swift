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
        for (offset, byte) in bytes.enumerated() {
            machine.bus.writeByte(byte, at: resetVector + UInt32(offset))
        }
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
