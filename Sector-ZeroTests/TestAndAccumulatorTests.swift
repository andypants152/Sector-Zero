import Testing
@testable import Sector_Zero

/// Milestone 20 — TEST (0x84/0x85, 0xA8/0xA9) and the accumulator-immediate
/// ALU shortcuts (0x04/0x05, 0x0C/0x0D, 0x24/0x25, 0x2C/0x2D, 0x34/0x35,
/// 0x3C/0x3D).
///
/// TEST computes AND but writes nothing (like CMP for SUB); its flags follow
/// the logical rule (CF = OF = 0). The accumulator forms are AL/AX with an
/// immediate, decoding straight to the existing immediate-ALU execution at
/// 4 clocks. Documented 8086 timings: TEST r/m,reg 3 (reg) / 9+EA (mem);
/// TEST acc,imm 4.
struct TestAndAccumulatorTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    @Test("84: TEST r/m8,r8 sets ZF and leaves both operands untouched")
    func testByteZero() {
        // MOV AL,0xF0; MOV BL,0x0F; TEST AL,BL → AND 0 → ZF set.
        let machine = machineWithOpcodes([0xB0, 0xF0, 0xB3, 0x0F, 0x84, 0xD8])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.ax & 0xFF == 0xF0) // AL unchanged
        #expect(machine.cpu.bx & 0xFF == 0x0F) // BL unchanged
        let flags = machine.snapshot().cpu.flags
        #expect(flags[.zero])
        #expect(!flags[.carry])
        #expect(!flags[.overflow])
        // MOV 4 + MOV 4 + TEST reg 3.
        #expect(machine.snapshot().cycleCount == 11)
    }

    @Test("84: TEST with a nonzero AND clears ZF, sets PF")
    func testByteNonzero() {
        // MOV AL,0xFF; MOV BL,0x0F; TEST AL,BL → 0x0F, ZF clear, PF set.
        let machine = machineWithOpcodes([0xB0, 0xFF, 0xB3, 0x0F, 0x84, 0xD8])
        machine.run(maxSteps: 3)
        let flags = machine.snapshot().cpu.flags
        #expect(!flags[.zero])
        #expect(flags[.parity]) // 0x0F has four set bits
        #expect(!flags[.sign])
    }

    @Test("85: TEST r/m16,r16 sets SF on a high-bit result")
    func testWordSign() {
        // MOV AX,0x8000; MOV BX,0x8000; TEST AX,BX → 0x8000, SF set.
        let machine = machineWithOpcodes([0xB8, 0x00, 0x80, 0xBB, 0x00, 0x80, 0x85, 0xD8])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.ax == 0x8000) // unchanged
        #expect(machine.cpu.bx == 0x8000)
        let flags = machine.snapshot().cpu.flags
        #expect(flags[.sign])
        #expect(!flags[.zero])
    }

    @Test("A8: TEST AL,imm8 sets flags without touching AL (4 clocks)")
    func testAccByte() {
        // MOV AL,0xF0; TEST AL,0x0F → ZF set, AL unchanged.
        let machine = machineWithOpcodes([0xB0, 0xF0, 0xA8, 0x0F])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax & 0xFF == 0xF0)
        #expect(machine.snapshot().cpu.flags[.zero])
        // MOV 4 + TEST acc 4.
        #expect(machine.snapshot().cycleCount == 8)
    }

    @Test("A9: TEST AX,imm16 leaves AX untouched")
    func testAccWord() {
        // MOV AX,0x1234; TEST AX,0x1000 → nonzero, AX unchanged.
        let machine = machineWithOpcodes([0xB8, 0x34, 0x12, 0xA9, 0x00, 0x10])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax == 0x1234)
        #expect(!machine.snapshot().cpu.flags[.zero])
    }

    @Test("04/05: ADD accumulator immediate (byte and word, 4 clocks)")
    func addAccumulator() {
        // MOV AL,0x10; ADD AL,0x05 → 0x15.
        let byte = machineWithOpcodes([0xB0, 0x10, 0x04, 0x05])
        byte.run(maxSteps: 2)
        #expect(byte.cpu.ax & 0xFF == 0x15)
        #expect(byte.snapshot().cycleCount == 8) // MOV 4 + ADD 4

        // MOV AX,0x1000; ADD AX,0x0234 → 0x1234.
        let word = machineWithOpcodes([0xB8, 0x00, 0x10, 0x05, 0x34, 0x02])
        word.run(maxSteps: 2)
        #expect(word.cpu.ax == 0x1234)
    }

    @Test("Each accumulator op decodes to the right operation")
    func accumulatorOpsCoverage() {
        // OR AL,0x0F; AND AL,0x0F; SUB AL,0x01; XOR AL,0x0F on fixed inputs.
        let or = machineWithOpcodes([0xB0, 0xF0, 0x0C, 0x0F]) // 0xF0 | 0x0F
        or.run(maxSteps: 2)
        #expect(or.cpu.ax & 0xFF == 0xFF)

        let and = machineWithOpcodes([0xB0, 0xFC, 0x24, 0x0F]) // 0xFC & 0x0F
        and.run(maxSteps: 2)
        #expect(and.cpu.ax & 0xFF == 0x0C)

        let sub = machineWithOpcodes([0xB0, 0x10, 0x2C, 0x01]) // 0x10 - 0x01
        sub.run(maxSteps: 2)
        #expect(sub.cpu.ax & 0xFF == 0x0F)

        let xor = machineWithOpcodes([0xB0, 0xFF, 0x34, 0x0F]) // 0xFF ^ 0x0F
        xor.run(maxSteps: 2)
        #expect(xor.cpu.ax & 0xFF == 0xF0)
    }

    @Test("3C: CMP AL,imm matches the 80 /7 long form's flags and leaves AL alone")
    func cmpAccumulatorParity() {
        // CMP AL,0x42 with AL=0x42 → equal.
        let short = machineWithOpcodes([0xB0, 0x42, 0x3C, 0x42])
        short.run(maxSteps: 2)
        let long = machineWithOpcodes([0xB0, 0x42, 0x80, 0xF8, 0x42])
        long.run(maxSteps: 2)
        #expect(short.cpu.ax & 0xFF == 0x42) // AL untouched by CMP
        #expect(short.snapshot().cpu.flags.rawValue == long.snapshot().cpu.flags.rawValue)
        #expect(short.snapshot().cpu.flags[.zero])
    }

    @Test("ADC/SBB accumulator forms decode through the shared selector")
    func adcSbbAccumulatorDecode() {
        let decoder = InstructionDecoder()
        #expect(decoder.decode(opcode: 0x14, registers: RegisterFile()) { 0 } == .aluImmediateToRM8(op: .adc, destination: .register(0), immediate: 0, eaClocks: 0))
        #expect(decoder.decode(opcode: 0x15, registers: RegisterFile()) { 0 } == .aluImmediateToRM16(op: .adc, destination: .register(0), immediate: 0, eaClocks: 0))
        #expect(decoder.decode(opcode: 0x1C, registers: RegisterFile()) { 0 } == .aluImmediateToRM8(op: .sbb, destination: .register(0), immediate: 0, eaClocks: 0))
        #expect(decoder.decode(opcode: 0x1D, registers: RegisterFile()) { 0 } == .aluImmediateToRM16(op: .sbb, destination: .register(0), immediate: 0, eaClocks: 0))
    }
}
