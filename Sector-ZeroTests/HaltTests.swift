import Testing
@testable import Sector_Zero

/// Milestone 5 — HLT and the halted run-state.
///
/// Executing HLT (0xF4, 2 clocks) puts the CPU into a halted state. While
/// halted, `Machine.step()` is a no-op — no fetch, no IP movement, no cycles.
/// Reset exits halt; M35 also allows an accepted NMI or enabled INTR to wake it.
/// `Machine.run(maxSteps:)` steps until halt or the bound, so tests can't hang.
struct HaltTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            machine.bus.writeByte(opcode, at: resetVector + UInt32(offset))
        }
        return machine
    }

    @Test("CPU is not halted after reset")
    func notHaltedAtReset() {
        let machine = Machine()
        #expect(machine.cpu.halted == false)
        #expect(machine.snapshot().cpu.halted == false)
    }

    @Test("Executing HLT halts the CPU and costs 2 cycles")
    func hltHaltsCPU() {
        let machine = machineWithOpcodes([0xF4])
        machine.step()
        let snapshot = machine.snapshot()
        #expect(snapshot.cpu.halted == true)
        #expect(snapshot.cpu.ip == 0x0001)
        #expect(snapshot.cycleCount == 2)
    }

    @Test("Stepping while halted freezes IP, cycles, and the fetched opcode")
    func stepWhileHaltedIsNoOp() {
        let machine = machineWithOpcodes([0xF4, 0x90])
        machine.step()
        let halted = machine.snapshot()

        machine.step()
        machine.step()
        let after = machine.snapshot()

        #expect(after.cpu.halted == true)
        #expect(after.cpu.ip == halted.cpu.ip)
        #expect(after.cycleCount == halted.cycleCount)
        #expect(after.cpu.lastFetchedOpcode == 0xF4)
    }

    @Test("Reset clears the halted state")
    func resetClearsHalt() {
        let machine = machineWithOpcodes([0xF4])
        machine.step()
        #expect(machine.cpu.halted == true)

        machine.reset()
        #expect(machine.cpu.halted == false)
        #expect(machine.snapshot().cpu.halted == false)
    }

    @Test("Machine can step again after a reset from halt")
    func stepsAgainAfterReset() {
        let machine = machineWithOpcodes([0xF4])
        machine.step()
        machine.reset()

        machine.step()
        let snapshot = machine.snapshot()
        #expect(snapshot.cpu.ip == 0x0001)
        #expect(snapshot.cycleCount == 2)
    }

    @Test("run(maxSteps:) executes until HLT")
    func runStopsAtHalt() {
        let machine = machineWithOpcodes([0x90, 0x90, 0xF4, 0x90])
        machine.run(maxSteps: 100)
        let snapshot = machine.snapshot()
        #expect(snapshot.cpu.halted == true)
        // Two NOPs (3 clocks each) + HLT (2 clocks); the trailing NOP never runs.
        #expect(snapshot.cpu.ip == 0x0003)
        #expect(snapshot.cycleCount == 8)
    }

    @Test("run(maxSteps:) respects its bound when no HLT is reached")
    func runRespectsBound() {
        let machine = machineWithOpcodes([0x90, 0x90, 0x90, 0x90])
        machine.run(maxSteps: 3)
        let snapshot = machine.snapshot()
        #expect(snapshot.cpu.halted == false)
        #expect(snapshot.cpu.ip == 0x0003)
        #expect(snapshot.cycleCount == 9)
    }
}
