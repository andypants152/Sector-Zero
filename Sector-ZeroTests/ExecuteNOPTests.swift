import Testing
@testable import Sector_Zero

/// Milestone 4 — execute NOP.
///
/// `Machine.step()` now runs a full fetch → decode → execute pass. Executing
/// NOP (0x90) changes no CPU state beyond the IP advance already performed by
/// the fetch, and charges NOP's documented 8086 cost of 3 clocks to the cycle
/// counter. The `.unknown` policy is no-op-and-advance: unrecognised opcodes
/// execute as a NOP (same provisional 3-clock cost) so stepping never wedges.
struct ExecuteNOPTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            machine.bus.writeByte(opcode, at: resetVector + UInt32(offset))
        }
        return machine
    }

    @Test("NOP advances IP by one and costs 3 cycles")
    func nopAdvancesIPAndCharges3Cycles() {
        let machine = machineWithOpcodes([0x90])
        machine.step()
        let snapshot = machine.snapshot()
        #expect(snapshot.cpu.ip == 0x0001)
        #expect(snapshot.cycleCount == 3)
    }

    @Test("NOP leaves registers and flags untouched")
    func nopLeavesStateUntouched() {
        let machine = machineWithOpcodes([0x90])
        let before = machine.snapshot().cpu
        machine.step()
        let after = machine.snapshot().cpu

        #expect(after.ax == before.ax)
        #expect(after.bx == before.bx)
        #expect(after.cx == before.cx)
        #expect(after.dx == before.dx)
        #expect(after.si == before.si)
        #expect(after.di == before.di)
        #expect(after.sp == before.sp)
        #expect(after.bp == before.bp)
        #expect(after.cs == before.cs)
        #expect(after.ds == before.ds)
        #expect(after.es == before.es)
        #expect(after.ss == before.ss)
        #expect(after.flags.rawValue == before.flags.rawValue)
    }

    @Test("Cycle cost accumulates across consecutive NOPs")
    func cyclesAccumulate() {
        let machine = machineWithOpcodes([0x90, 0x90, 0x90])
        machine.step()
        machine.step()
        machine.step()
        let snapshot = machine.snapshot()
        #expect(snapshot.cpu.ip == 0x0003)
        #expect(snapshot.cycleCount == 9)
    }

    @Test("Unknown opcode executes as no-op-and-advance")
    func unknownOpcodeIsNoOpAndAdvance() {
        let machine = machineWithOpcodes([0x60])
        let before = machine.snapshot().cpu
        machine.step()
        let after = machine.snapshot()

        #expect(after.cpu.ip == 0x0001)
        #expect(after.cycleCount == 3)
        #expect(after.cpu.ax == before.ax)
        #expect(after.cpu.flags.rawValue == before.flags.rawValue)
        #expect(after.cpu.lastFetchedOpcode == 0x60)
    }

    @Test("Reset clears accumulated cycles")
    func resetClearsCycles() {
        let machine = machineWithOpcodes([0x90, 0x90])
        machine.step()
        machine.step()
        #expect(machine.snapshot().cycleCount == 6)

        machine.reset()
        let snapshot = machine.snapshot()
        #expect(snapshot.cycleCount == 0)
        #expect(snapshot.cpu.ip == 0x0000)
    }
}
