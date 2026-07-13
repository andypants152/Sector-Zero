import Testing
@testable import Sector_Zero

/// Milestone 13 — PUSH/POP reg16 (0x50–0x5F).
///
/// The 8086 stack lives at SS:SP and grows downward: PUSH decrements SP by 2
/// then writes the word at SS:SP; POP reads then increments. The low three
/// opcode bits are the register encoding. PUSH is 11 clocks, POP 8. Quirk:
/// PUSH SP pushes the *already-decremented* SP (unlike the 80286+).
struct StackTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            let address = (resetVector + UInt32(offset)) & AddressTranslator.physicalAddressMask
            machine.bus.writeByte(opcode, at: address)
        }
        return machine
    }

    @Test("50: PUSH AX writes at SS:SP-2 and decrements SP")
    func pushWritesBelowSP() {
        // MOV SP, 0x0100; MOV AX, 0xBEEF; PUSH AX.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xB8, 0xEF, 0xBE, 0x50])
        machine.cpu.writeSegment(0x2000, to: .ss)
        machine.run(maxSteps: 3)
        #expect(machine.cpu.sp == 0x00FE)
        #expect(machine.bus.readByte(at: 0x200FE) == 0xEF) // little-endian at SS:0x00FE
        #expect(machine.bus.readByte(at: 0x200FF) == 0xBE)
        // MOV 4 + MOV 4 + PUSH 11.
        #expect(machine.snapshot().cycleCount == 19)
    }

    @Test("58: POP restores the pushed word and re-increments SP (8 clocks)")
    func popRoundTrip() {
        // MOV SP, 0x0100; MOV AX, 0x1234; PUSH AX; POP BX.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xB8, 0x34, 0x12, 0x50, 0x5B])
        machine.run(maxSteps: 4)
        #expect(machine.cpu.bx == 0x1234)
        #expect(machine.cpu.sp == 0x0100)
        // 4 + 4 + 11 + 8.
        #expect(machine.snapshot().cycleCount == 27)
    }

    @Test("Multiple pushes pop back in LIFO order")
    func lifoOrder() {
        // MOV SP,0x0200; MOV AX,1; MOV BX,2; MOV CX,3;
        // PUSH AX; PUSH BX; PUSH CX; POP SI; POP DI; POP DX.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x02,
            0xB8, 0x01, 0x00, 0xBB, 0x02, 0x00, 0xB9, 0x03, 0x00,
            0x50, 0x53, 0x51,
            0x5E, 0x5F, 0x5A,
        ])
        machine.run(maxSteps: 10)
        #expect(machine.cpu.si == 0x0003) // last pushed (CX) pops first
        #expect(machine.cpu.di == 0x0002)
        #expect(machine.cpu.dx == 0x0001)
        #expect(machine.cpu.sp == 0x0200)
    }

    @Test("Stack reads and writes go through SS, not DS")
    func stackUsesSS() {
        // MOV SP, 0x0010; MOV AX, 0xCAFE; PUSH AX.
        let machine = machineWithOpcodes([0xBC, 0x10, 0x00, 0xB8, 0xFE, 0xCA, 0x50])
        machine.cpu.writeSegment(0x3000, to: .ss)
        machine.cpu.writeSegment(0x1000, to: .ds)
        machine.run(maxSteps: 3)
        #expect(machine.bus.readByte(at: 0x3000E) == 0xFE) // SS:0x000E
        #expect(machine.bus.readByte(at: 0x1000E) == 0x00) // DS untouched
    }

    @Test("SP wraps below zero")
    func spWrapsAtZero() {
        // SP is 0 at reset; PUSH AX wraps it to 0xFFFE.
        let machine = machineWithOpcodes([0x50])
        machine.step()
        #expect(machine.cpu.sp == 0xFFFE)
    }

    @Test("PUSH SP pushes the already-decremented value (8086 quirk)")
    func pushSPQuirk() {
        // MOV SP, 0x0100; PUSH SP (54); POP AX.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0x54, 0x58])
        machine.run(maxSteps: 3)
        // The 8086 stores 0x00FE (post-decrement), not 0x0100.
        #expect(machine.cpu.ax == 0x00FE)
        #expect(machine.cpu.sp == 0x0100)
    }

    @Test("POP SP loads the popped value as the new SP")
    func popSPLoadsValue() {
        // MOV SP, 0x0100; MOV AX, 0x0555; PUSH AX; POP SP (5C).
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xB8, 0x55, 0x05, 0x50, 0x5C])
        machine.run(maxSteps: 4)
        #expect(machine.cpu.sp == 0x0555)
    }

    @Test("PUSH and POP leave the flags untouched")
    func stackOpsPreserveFlags() {
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0x50, 0x58])
        let before = machine.snapshot().cpu.flags.rawValue
        machine.run(maxSteps: 3)
        #expect(machine.snapshot().cpu.flags.rawValue == before)
    }
}
