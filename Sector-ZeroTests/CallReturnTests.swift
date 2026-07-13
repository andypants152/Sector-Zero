import Testing
@testable import Sector_Zero

/// Milestone 14 — CALL near-relative (0xE8) and RET near (0xC3).
///
/// CALL fetches a little-endian 16-bit displacement, pushes the return IP
/// (the address of the instruction after the CALL), then adds the
/// displacement to IP with 16-bit wrap. RET pops IP. CALL is 19 clocks,
/// RET 16.
struct CallReturnTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    @Test("E8: CALL forward pushes the return IP and lands at the target")
    func callForward() {
        // MOV SP, 0x0100; CALL +5. The CALL starts at IP 0x0003 and is three
        // bytes long, so the return IP is 0x0006 and the target 0x000B.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xE8, 0x05, 0x00])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ip == 0x000B)
        #expect(machine.cpu.sp == 0x00FE)
        // Return IP 0x0006 sits little-endian at SS:0x00FE (SS is 0 at reset).
        #expect(machine.bus.readByte(at: 0x000FE) == 0x06)
        #expect(machine.bus.readByte(at: 0x000FF) == 0x00)
        // MOV 4 + CALL 19.
        #expect(machine.snapshot().cycleCount == 23)
    }

    @Test("E8: CALL backward wraps IP within the segment")
    func callBackwardWraps() {
        // MOV SP, 0x0100; CALL -0x20. Return IP 0x0006; target 0x0006 - 0x20
        // wraps to 0xFFE6.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xE8, 0xE0, 0xFF])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ip == 0xFFE6)
        #expect(machine.bus.readByte(at: 0x000FE) == 0x06)
    }

    @Test("C3: RET resumes at the instruction after the CALL (16 clocks)")
    func retResumesAfterCall() {
        // MOV SP, 0x0100; CALL +1; HLT; RET.
        // The subroutine is a lone RET; execution must come back to the HLT.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xE8, 0x01, 0x00, 0xF4, 0xC3])
        machine.run(maxSteps: 10)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.sp == 0x0100)
        // MOV 4 + CALL 19 + RET 16 + HLT 2.
        #expect(machine.snapshot().cycleCount == 41)
    }

    @Test("Nested calls unwind in order")
    func nestedCallsUnwind() {
        // Outer routine `a` marks AL, calls `b` (which marks CL), then marks
        // BL after the inner return — so BL proves control came back to `a`
        // before the outer RET reaches the HLT.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x02,        // 0x0000 MOV SP,0x0200
            0xE8, 0x03, 0x00,        // 0x0003 CALL a (0x0009)
            0xF4,                    // 0x0006 HLT
            0x90, 0x90,              // padding
            0xB0, 0x01,              // 0x0009 a: MOV AL,1
            0xE8, 0x03, 0x00,        // 0x000B CALL b (0x0011)
            0xB3, 0x01,              // 0x000E MOV BL,1
            0xC3,                    // 0x0010 RET
            0xB1, 0x01,              // 0x0011 b: MOV CL,1
            0xC3,                    // 0x0013 RET
        ])
        machine.run(maxSteps: 30)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.ax & 0xFF == 1)
        #expect(machine.cpu.bx & 0xFF == 1)
        #expect(machine.cpu.cx & 0xFF == 1)
        #expect(machine.cpu.sp == 0x0200)
    }

    @Test("End-to-end: a called subroutine computes, returns, and halts")
    func endToEndProgram() {
        // MOV SP,0x0100; MOV AX,5; MOV BX,7; CALL sum; HLT; sum: ADD AX,BX; RET.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,        // 0x0000 MOV SP,0x0100
            0xB8, 0x05, 0x00,        // 0x0003 MOV AX,5
            0xBB, 0x07, 0x00,        // 0x0006 MOV BX,7
            0xE8, 0x01, 0x00,        // 0x0009 CALL 0x000D
            0xF4,                    // 0x000C HLT
            0x01, 0xD8,              // 0x000D ADD AX,BX
            0xC3,                    // 0x000F RET
        ])
        machine.run(maxSteps: 20)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.ax == 12)
        #expect(machine.cpu.bx == 7)
        #expect(machine.cpu.sp == 0x0100)
        #expect(machine.cpu.ip == 0x000D) // fetch of HLT advanced IP past it
    }

    @Test("CALL and RET leave the flags untouched")
    func callRetPreserveFlags() {
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xE8, 0x01, 0x00, 0xF4, 0xC3])
        let before = machine.snapshot().cpu.flags.rawValue
        machine.run(maxSteps: 10)
        #expect(machine.snapshot().cpu.flags.rawValue == before)
    }
}
