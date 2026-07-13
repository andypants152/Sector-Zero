import Testing
@testable import Sector_Zero

/// Milestone 21 — XCHG (0x86/0x87, 0x91–0x97) and the remaining MOV forms:
/// accumulator ↔ direct-address moffs (0xA0–0xA3) and MOV r/m,imm (0xC6/0xC7).
///
/// None of these touch flags. Cycles: XCHG reg↔reg 4 / mem 17+EA; XCHG AX,reg
/// 3; moffs 10; MOV r/m,imm reg 4 / mem 10+EA.
struct ExchangeAndMovTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    @Test("87: XCHG r16,r16 swaps registers without touching flags")
    func exchangeWordRegisters() {
        // MOV AX,0x1111; MOV BX,0x2222; XCHG AX,BX.
        let machine = machineWithOpcodes([0xB8, 0x11, 0x11, 0xBB, 0x22, 0x22, 0x87, 0xC3])
        let flagsBefore = Machine().snapshot().cpu.flags.rawValue
        machine.run(maxSteps: 3)
        #expect(machine.cpu.ax == 0x2222)
        #expect(machine.cpu.bx == 0x1111)
        #expect(machine.snapshot().cpu.flags.rawValue == flagsBefore)
        #expect(machine.snapshot().cycleCount == 12) // 4 + 4 + 4
    }

    @Test("86: XCHG r8,r8 swaps byte registers")
    func exchangeByteRegisters() {
        // MOV AL,0xAA; MOV BL,0xBB; XCHG AL,BL.
        let machine = machineWithOpcodes([0xB0, 0xAA, 0xB3, 0xBB, 0x86, 0xC3])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.ax & 0xFF == 0xBB)
        #expect(machine.cpu.bx & 0xFF == 0xAA)
    }

    @Test("87: XCHG r16,mem swaps register with memory (17+EA)")
    func exchangeWordMemory() {
        // MOV AX,0x1234; word 0x5678 at DS:0x0080; XCHG AX,[0x0080].
        let machine = machineWithOpcodes([0xB8, 0x34, 0x12, 0x87, 0x06, 0x80, 0x00])
        machine.bus.writeByte(0x78, at: 0x0080)
        machine.bus.writeByte(0x56, at: 0x0081)
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax == 0x5678)
        #expect(machine.bus.readByte(at: 0x0080) == 0x34)
        #expect(machine.bus.readByte(at: 0x0081) == 0x12)
        #expect(machine.snapshot().cycleCount == 27) // MOV 4 + 17 + EA 6
    }

    @Test("91/96: XCHG AX,reg one-byte forms (3 clocks)")
    func exchangeAXWithRegister() {
        // MOV AX,0x1111; MOV CX,0x2222; XCHG AX,CX (0x91).
        let cx = machineWithOpcodes([0xB8, 0x11, 0x11, 0xB9, 0x22, 0x22, 0x91])
        cx.run(maxSteps: 3)
        #expect(cx.cpu.ax == 0x2222)
        #expect(cx.cpu.cx == 0x1111)
        #expect(cx.snapshot().cycleCount == 11) // 4 + 4 + 3

        // MOV AX,0xAAAA; MOV SI,0x5555; XCHG AX,SI (0x96).
        let si = machineWithOpcodes([0xB8, 0xAA, 0xAA, 0xBE, 0x55, 0x55, 0x96])
        si.run(maxSteps: 3)
        #expect(si.cpu.ax == 0x5555)
        #expect(si.cpu.si == 0xAAAA)
    }

    @Test("A0/A1: MOV accumulator from a direct memory offset (10 clocks)")
    func movAccumulatorFromOffset() {
        // Byte 0x42 at DS:0x0080; MOV AL,[0x0080].
        let byte = machineWithOpcodes([0xA0, 0x80, 0x00])
        byte.bus.writeByte(0x42, at: 0x0080)
        byte.step()
        #expect(byte.cpu.ax & 0xFF == 0x42)
        #expect(byte.snapshot().cycleCount == 10)

        // Word 0x1234 at DS:0x0080; MOV AX,[0x0080].
        let word = machineWithOpcodes([0xA1, 0x80, 0x00])
        word.bus.writeByte(0x34, at: 0x0080)
        word.bus.writeByte(0x12, at: 0x0081)
        word.step()
        #expect(word.cpu.ax == 0x1234)
    }

    @Test("A2/A3: MOV a direct memory offset from the accumulator")
    func movOffsetFromAccumulator() {
        // MOV AL,0x99; MOV [0x0080],AL.
        let byte = machineWithOpcodes([0xB0, 0x99, 0xA2, 0x80, 0x00])
        byte.run(maxSteps: 2)
        #expect(byte.bus.readByte(at: 0x0080) == 0x99)

        // MOV AX,0xABCD; MOV [0x0080],AX (little-endian).
        let word = machineWithOpcodes([0xB8, 0xCD, 0xAB, 0xA3, 0x80, 0x00])
        word.run(maxSteps: 2)
        #expect(word.bus.readByte(at: 0x0080) == 0xCD)
        #expect(word.bus.readByte(at: 0x0081) == 0xAB)
    }

    @Test("A1: moffs addresses through DS")
    func movOffsetUsesDS() {
        // DS = 0x2000; word 0xBEEF at 0x20080; MOV AX,[0x0080].
        let machine = machineWithOpcodes([0xA1, 0x80, 0x00])
        machine.cpu.writeSegment(0x2000, to: .ds)
        machine.bus.writeByte(0xEF, at: 0x20080)
        machine.bus.writeByte(0xBE, at: 0x20081)
        machine.step()
        #expect(machine.cpu.ax == 0xBEEF)
    }

    @Test("C6: MOV r/m8,imm8 to a register (4 clocks)")
    func movImmediateToRegisterByte() {
        // MOV BL,0x55 via C6 /0 (r/m = BL).
        let machine = machineWithOpcodes([0xC6, 0xC3, 0x55])
        machine.step()
        #expect(machine.cpu.bx & 0xFF == 0x55)
        #expect(machine.snapshot().cycleCount == 4)
    }

    @Test("C7: MOV r/m16,imm16 to memory consumes the full 6-byte instruction")
    func movImmediateToMemoryWord() {
        // MOV word [0x0080],0x1234 → C7 06 80 00 34 12.
        let machine = machineWithOpcodes([0xC7, 0x06, 0x80, 0x00, 0x34, 0x12])
        machine.step()
        #expect(machine.bus.readByte(at: 0x0080) == 0x34)
        #expect(machine.bus.readByte(at: 0x0081) == 0x12)
        #expect(machine.cpu.ip == 6) // opcode + modrm + disp16 + imm16
        #expect(machine.snapshot().cycleCount == 16) // 10 + EA 6
    }

    @Test("C7: MOV r/m16,imm16 to a register")
    func movImmediateToRegisterWord() {
        // MOV BX,0x1234 via C7 /0 (r/m = BX).
        let machine = machineWithOpcodes([0xC7, 0xC3, 0x34, 0x12])
        machine.step()
        #expect(machine.cpu.bx == 0x1234)
    }

    @Test("C6/C7 with a nonzero ModR/M reg field decode to .unknown")
    func movImmediateRequiresRegZero() {
        let decoder = InstructionDecoder()
        // C6 with reg=/1 (ModR/M 0xC8): undefined, still consumes its bytes.
        var stream: [UInt8] = [0xC8, 0x55]
        #expect(decoder.decode(opcode: 0xC6, registers: RegisterFile()) { stream.removeFirst() } == .unknown(0xC6))
    }
}
