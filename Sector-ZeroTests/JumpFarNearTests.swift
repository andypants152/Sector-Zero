import Testing
@testable import Sector_Zero

/// Milestone 18 — JMP near (0xE9) and JMP far (0xEA).
///
/// `E9` is a signed disp16 relative to the next instruction (16-bit wrap).
/// `EA` is a direct intersegment jump: little-endian offset then segment,
/// loaded into IP and CS. Both cost 15 clocks and touch no flags.
struct JumpFarNearTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    @Test("E9: JMP near forward lands past the operand (15 clocks)")
    func nearForward() {
        // JMP near +5 at offset 0: the 3-byte instruction leaves IP at 3,
        // then +5 → 8. CS is unchanged.
        let machine = machineWithOpcodes([0xE9, 0x05, 0x00])
        machine.step()
        #expect(machine.cpu.ip == 8)
        #expect(machine.cpu.cs == 0xFFFF)
        #expect(machine.snapshot().physicalCodeAddress == 0xFFFF0 + 8)
        #expect(machine.snapshot().cycleCount == 15)
    }

    @Test("E9: JMP near backward reaches the instruction's own start")
    func nearBackward() {
        // JMP near -3 at offset 0: IP 3 → 0.
        let machine = machineWithOpcodes([0xE9, 0xFD, 0xFF])
        machine.step()
        #expect(machine.cpu.ip == 0)
    }

    @Test("E9: JMP near wraps IP below zero within the segment")
    func nearWraps() {
        // JMP near -0x10 at offset 0: IP 3 → 3 - 0x10 = 0xFFF3.
        let machine = machineWithOpcodes([0xE9, 0xF0, 0xFF])
        machine.step()
        #expect(machine.cpu.ip == 0xFFF3)
    }

    @Test("EA: JMP far loads both CS and IP; the fetch address reflects both")
    func farLoadsSegmentAndOffset() {
        // JMP 0x1234:0x5678 → EA 78 56 34 12.
        let machine = machineWithOpcodes([0xEA, 0x78, 0x56, 0x34, 0x12])
        machine.step()
        #expect(machine.cpu.ip == 0x5678)
        #expect(machine.cpu.cs == 0x1234)
        // 0x1234 * 16 + 0x5678 = 0x179B8.
        #expect(machine.snapshot().physicalCodeAddress == 0x179B8)
        #expect(machine.snapshot().cycleCount == 15)
    }

    @Test("EA: execution continues at the far target")
    func farTargetExecutes() {
        // JMP 0x0100:0x0002, with a HLT waiting at physical 0x1002.
        let machine = machineWithOpcodes([0xEA, 0x02, 0x00, 0x00, 0x01])
        machine.bus.writeByte(0xF4, at: 0x1002)
        machine.run(maxSteps: 3)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.cs == 0x0100)
        #expect(machine.cpu.ip == 0x0003) // HLT fetched, IP advanced past it
    }

    @Test("EA: the BIOS handoff — far jump from the reset segment to low memory")
    func biosHandoffShape() {
        // At the reset vector (FFFF:0000), JMP 0x0040:0x0000 → physical 0x400,
        // where a HLT stands in for the relocated boot code.
        let machine = machineWithOpcodes([0xEA, 0x00, 0x00, 0x40, 0x00])
        machine.bus.writeByte(0xF4, at: 0x400)
        machine.run(maxSteps: 3)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.cs == 0x0040)
        #expect(machine.cpu.ip == 0x0001)
    }

    @Test("Neither jump form disturbs the flags")
    func jumpsPreserveFlags() {
        let near = machineWithOpcodes([0xE9, 0x05, 0x00])
        let far = machineWithOpcodes([0xEA, 0x78, 0x56, 0x34, 0x12])
        let before = Machine().snapshot().cpu.flags.rawValue
        near.step()
        far.step()
        #expect(near.snapshot().cpu.flags.rawValue == before)
        #expect(far.snapshot().cpu.flags.rawValue == before)
    }
}
