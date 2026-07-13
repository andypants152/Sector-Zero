import Testing
@testable import Sector_Zero

/// Milestone 22 — segment registers: MOV sreg (0x8C/0x8E), PUSH/POP sreg
/// (0x06–0x1F evens, incl. 0x0F POP CS), and segment-override prefixes
/// (0x26/0x2E/0x36/0x3E).
///
/// The reg field of 8C/8E and the bits 4–3 of the push/pop opcodes select
/// ES(0)/CS(1)/SS(2)/DS(3). Override prefixes redirect the *next* instruction's
/// data-operand segment (not stack or code), cost 2 clocks, and last-one-wins.
struct SegmentTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    // MARK: MOV sreg

    @Test("8E: MOV sreg,r16 loads a segment register (2 clocks)")
    func movRegisterToSegment() {
        // MOV BX,0x2000; MOV DS,BX (8E DB: reg=DS/3, r/m=BX/3).
        let machine = machineWithOpcodes([0xBB, 0x00, 0x20, 0x8E, 0xDB])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ds == 0x2000)
        #expect(machine.snapshot().cycleCount == 6) // MOV imm 4 + MOV sreg 2
    }

    @Test("8C: MOV r16,sreg stores a segment register")
    func movSegmentToRegister() {
        // MOV BX,0x1234; MOV ES,BX (8E C3); MOV AX,ES (8C C0).
        let machine = machineWithOpcodes([0xBB, 0x34, 0x12, 0x8E, 0xC3, 0x8C, 0xC0])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.es == 0x1234)
        #expect(machine.cpu.ax == 0x1234)
    }

    @Test("8E: MOV sreg from memory (8+EA)")
    func movMemoryToSegment() {
        // Word 0x3000 at DS:0x0080; MOV ES,[0x0080] (8E 06 80 00).
        let machine = machineWithOpcodes([0x8E, 0x06, 0x80, 0x00])
        machine.bus.writeByte(0x00, at: 0x0080)
        machine.bus.writeByte(0x30, at: 0x0081)
        machine.step()
        #expect(machine.cpu.es == 0x3000)
        #expect(machine.snapshot().cycleCount == 14) // 8 + EA 6
    }

    @Test("8C: MOV sreg to memory stores little-endian (9+EA)")
    func movSegmentToMemory() {
        // SS=0x4000; MOV [0x0080],SS (8C 16 80 00).
        let machine = machineWithOpcodes([0x8C, 0x16, 0x80, 0x00])
        machine.cpu.writeSegment(0x4000, to: .ss)
        machine.step()
        #expect(machine.bus.readByte(at: 0x0080) == 0x00)
        #expect(machine.bus.readByte(at: 0x0081) == 0x40)
        #expect(machine.snapshot().cycleCount == 15) // 9 + EA 6
    }

    @Test("8E: MOV CS,r16 is accepted on the 8086 and redirects fetch")
    func movToCSIsAllowed() {
        // MOV BX,0x3000; MOV CS,BX (8E CB: reg=CS/1, r/m=BX/3).
        let machine = machineWithOpcodes([0xBB, 0x00, 0x30, 0x8E, 0xCB])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.cs == 0x3000)
    }

    // MARK: PUSH/POP sreg

    @Test("1E/07: PUSH DS then POP ES round-trips through the stack")
    func pushPopSegment() {
        // MOV SP,0x0100; DS=0x1234; PUSH DS (1E); POP ES (07).
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0x1E, 0x07])
        machine.cpu.writeSegment(0x1234, to: .ds)
        machine.run(maxSteps: 3)
        #expect(machine.cpu.es == 0x1234)
        #expect(machine.cpu.sp == 0x0100)
        // MOV 4 + PUSH sreg 10 + POP sreg 8.
        #expect(machine.snapshot().cycleCount == 22)
    }

    @Test("Each PUSH sreg opcode selects the right segment")
    func pushSegmentSelectors() {
        // ES/SS/DS set to distinct values; push each, pop into AX, check.
        // (CS is excluded here — repointing it would move instruction fetch.)
        for (push, value, segment): (UInt8, UInt16, SegmentRegister) in
            [(0x06, 0x1111, .es), (0x16, 0x3333, .ss), (0x1E, 0x4444, .ds)] {
            // MOV SP,0x0100; PUSH sreg; POP AX (58).
            let machine = machineWithOpcodes([0xBC, 0x00, 0x01, push, 0x58])
            machine.cpu.writeSegment(value, to: segment)
            machine.run(maxSteps: 3)
            #expect(machine.cpu.ax == value)
        }

        // PUSH CS (0x0E) pushes the current CS — 0xFFFF at reset.
        let cs = machineWithOpcodes([0xBC, 0x00, 0x01, 0x0E, 0x58])
        cs.run(maxSteps: 3)
        #expect(cs.cpu.ax == 0xFFFF)
    }

    @Test("0F: POP CS is the 8086's encoding and loads CS")
    func popCSQuirk() {
        // MOV SP,0x0100; MOV AX,0x3000; PUSH AX; POP CS (0F).
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xB8, 0x00, 0x30, 0x50, 0x0F])
        machine.run(maxSteps: 4)
        #expect(machine.cpu.cs == 0x3000)

        // And the decoder maps it explicitly.
        let decoder = InstructionDecoder()
        #expect(decoder.decode(opcode: 0x0F, registers: RegisterFile()) { 0 } == .popSegment(.cs))
    }

    // MARK: Override prefixes

    @Test("26: an ES override redirects a DS-default operand to ES")
    func overrideRedirectsToES() {
        // ES=0x3000, DS=0x1000; ES: MOV AX,[0x0080] (26 8B 06 80 00).
        let machine = machineWithOpcodes([0x26, 0x8B, 0x06, 0x80, 0x00])
        machine.cpu.writeSegment(0x3000, to: .es)
        machine.cpu.writeSegment(0x1000, to: .ds)
        machine.bus.writeByte(0xEF, at: 0x30080) // ES:0x0080
        machine.bus.writeByte(0xBE, at: 0x30081)
        machine.bus.writeByte(0xAD, at: 0x10080) // DS:0x0080
        machine.bus.writeByte(0xDE, at: 0x10081)
        machine.step()
        #expect(machine.cpu.ax == 0xBEEF)
        #expect(machine.cpu.ip == 5) // prefix + opcode + modrm + disp16
        #expect(machine.snapshot().cycleCount == 16) // prefix 2 + MOV mem→reg 8+EA 6
    }

    @Test("3E: a DS override redirects a BP-based (SS-default) operand to DS")
    func overrideRedirectsBPToDS() {
        // SS=0x2000, DS=0x1000, BP=0x0080.
        // With override: DS: MOV AX,[BP] (3E 8B 46 00) → reads DS:0x0080.
        let overridden = machineWithOpcodes([0xBD, 0x80, 0x00, 0x3E, 0x8B, 0x46, 0x00])
        overridden.cpu.writeSegment(0x2000, to: .ss)
        overridden.cpu.writeSegment(0x1000, to: .ds)
        overridden.bus.writeByte(0xFE, at: 0x20080); overridden.bus.writeByte(0xCA, at: 0x20081) // SS
        overridden.bus.writeByte(0x0D, at: 0x10080); overridden.bus.writeByte(0xF0, at: 0x10081) // DS
        overridden.run(maxSteps: 2)
        #expect(overridden.cpu.ax == 0xF00D)

        // Without override the same access defaults to SS.
        let plain = machineWithOpcodes([0xBD, 0x80, 0x00, 0x8B, 0x46, 0x00])
        plain.cpu.writeSegment(0x2000, to: .ss)
        plain.cpu.writeSegment(0x1000, to: .ds)
        plain.bus.writeByte(0xFE, at: 0x20080); plain.bus.writeByte(0xCA, at: 0x20081)
        plain.bus.writeByte(0x0D, at: 0x10080); plain.bus.writeByte(0xF0, at: 0x10081)
        plain.run(maxSteps: 2)
        #expect(plain.cpu.ax == 0xCAFE)
    }

    @Test("An override applies to one instruction only")
    func overrideDoesNotLeak() {
        // ES=0x3000, DS=0x1000; ES: MOV AX,[0x80]; MOV BX,[0x80] (no prefix).
        let machine = machineWithOpcodes([0x26, 0x8B, 0x06, 0x80, 0x00, 0x8B, 0x1E, 0x80, 0x00])
        machine.cpu.writeSegment(0x3000, to: .es)
        machine.cpu.writeSegment(0x1000, to: .ds)
        machine.bus.writeByte(0xEF, at: 0x30080); machine.bus.writeByte(0xBE, at: 0x30081)
        machine.bus.writeByte(0xAD, at: 0x10080); machine.bus.writeByte(0xDE, at: 0x10081)
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax == 0xBEEF) // ES (overridden)
        #expect(machine.cpu.bx == 0xDEAD) // DS (override cleared)
    }

    @Test("26: an override also redirects a moffs access")
    func overrideRedirectsMoffs() {
        // ES=0x3000; ES: MOV AX,[0x0080] (26 A1 80 00).
        let machine = machineWithOpcodes([0x26, 0xA1, 0x80, 0x00])
        machine.cpu.writeSegment(0x3000, to: .es)
        machine.bus.writeByte(0x34, at: 0x30080)
        machine.bus.writeByte(0x12, at: 0x30081)
        machine.step()
        #expect(machine.cpu.ax == 0x1234)
    }

    @Test("A stack push ignores a segment override")
    func overrideIgnoredByStack() {
        // ES=0x3000, SS=0x2000, SP=0x0100; ES: PUSH AX with AX=0x5678.
        // The push must land at SS:0x00FE regardless of the ES prefix.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xB8, 0x78, 0x56, 0x26, 0x50])
        machine.cpu.writeSegment(0x3000, to: .es)
        machine.cpu.writeSegment(0x2000, to: .ss)
        machine.run(maxSteps: 4)
        #expect(machine.bus.readByte(at: 0x200FE) == 0x78) // SS, not ES
        #expect(machine.bus.readByte(at: 0x200FF) == 0x56)
    }
}
