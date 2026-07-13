import Testing
@testable import Sector_Zero

/// Milestone 15 — Immediate ALU forms (0x80, 0x81, 0x83).
///
/// The ModR/M reg field selects the operation (all eight ALU selectors); the
/// immediate follows the ModR/M byte and any displacement. 0x80 takes imm8,
/// 0x81 imm16 (little-endian), 0x83 a sign-extended imm8 applied to a 16-bit
/// destination. Cycles: register 4; memory 17+EA (CMP, which only reads,
/// 10+EA).
struct ImmediateALUTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    @Test("80 /0: ADD reg8, imm8 (4 clocks)")
    func addByteImmediateToRegister() {
        // MOV AL, 0x10; ADD AL, 0x05.
        let machine = machineWithOpcodes([0xB0, 0x10, 0x80, 0xC0, 0x05])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax & 0xFF == 0x15)
        // MOV 4 + ADD 4.
        #expect(machine.snapshot().cycleCount == 8)
    }

    @Test("80 /5: SUB reg8, imm8 sets borrow flags like the register form")
    func subByteImmediateFlags() {
        // MOV AL, 0x10; SUB AL, 0x20 → 0xF0, CF and SF set, ZF clear.
        let machine = machineWithOpcodes([0xB0, 0x10, 0x80, 0xE8, 0x20])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax & 0xFF == 0xF0)
        let flags = machine.snapshot().cpu.flags
        #expect(flags[.carry])
        #expect(flags[.sign])
        #expect(!flags[.zero])
    }

    @Test("80 /7: CMP reg8, imm8 updates flags but not the register")
    func cmpByteImmediate() {
        // MOV AL, 0x42; CMP AL, 0x42 → ZF set, AL unchanged.
        let machine = machineWithOpcodes([0xB0, 0x42, 0x80, 0xF8, 0x42])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax & 0xFF == 0x42)
        #expect(machine.snapshot().cpu.flags[.zero])
    }

    @Test("81 /0: ADD reg16, imm16 (little-endian immediate)")
    func addWordImmediateToRegister() {
        // MOV BX, 0x1111; ADD BX, 0x2345.
        let machine = machineWithOpcodes([0xBB, 0x11, 0x11, 0x81, 0xC3, 0x45, 0x23])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.bx == 0x3456)
        #expect(machine.snapshot().cycleCount == 8)
    }

    @Test("81 /5: SUB word memory destination is read-modify-write (17+EA)")
    func subWordImmediateToMemory() {
        // Word 0x5000 at DS:0x0080; SUB word [0x0080], 0x1234.
        let machine = machineWithOpcodes([0x81, 0x2E, 0x80, 0x00, 0x34, 0x12])
        machine.cpu.writeSegment(0x1000, to: .ds)
        machine.bus.writeByte(0x00, at: 0x10080)
        machine.bus.writeByte(0x50, at: 0x10081)
        machine.step()
        #expect(machine.bus.readByte(at: 0x10080) == 0xCC) // 0x5000-0x1234 = 0x3DCC
        #expect(machine.bus.readByte(at: 0x10081) == 0x3D)
        // 17 + 6 (direct-address EA).
        #expect(machine.snapshot().cycleCount == 23)
    }

    @Test("80 /7: CMP memory destination only reads (10+EA)")
    func cmpByteMemoryCycles() {
        // Byte 0x07 at DS:0x0040; CMP byte [0x0040], 0x07.
        let machine = machineWithOpcodes([0x80, 0x3E, 0x40, 0x00, 0x07])
        machine.bus.writeByte(0x07, at: 0x00040)
        machine.step()
        #expect(machine.bus.readByte(at: 0x00040) == 0x07)
        #expect(machine.snapshot().cpu.flags[.zero])
        #expect(machine.snapshot().cycleCount == 16) // 10 + 6
    }

    @Test("83 /0: ADD reg16 sign-extends a negative imm8")
    func addSignExtendedNegative() {
        // MOV BX, 0x0005; ADD BX, -1 (0xFF → 0xFFFF).
        let machine = machineWithOpcodes([0xBB, 0x05, 0x00, 0x83, 0xC3, 0xFF])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.bx == 0x0004)
        #expect(machine.snapshot().cpu.flags[.carry]) // 5 + 0xFFFF carries out
    }

    @Test("83 /0: ADD reg16 zero-extends a positive imm8")
    func addSignExtendedPositive() {
        // MOV BX, 0x00FE; ADD BX, +0x7F.
        let machine = machineWithOpcodes([0xBB, 0xFE, 0x00, 0x83, 0xC3, 0x7F])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.bx == 0x017D)
    }

    @Test("83 /7: CMP reg16 against a sign-extended imm8")
    func cmpSignExtended() {
        // MOV BX, 0xFFFF; CMP BX, -1 → equal, ZF set, no borrow.
        let machine = machineWithOpcodes([0xBB, 0xFF, 0xFF, 0x83, 0xFB, 0xFF])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.bx == 0xFFFF)
        let flags = machine.snapshot().cpu.flags
        #expect(flags[.zero])
        #expect(!flags[.carry])
    }

    @Test("Immediate forms set the same flags as the register forms")
    func flagParityWithRegisterForm() {
        // ADD AL,0x7F when AL=0x01 must overflow identically both ways.
        let immediate = machineWithOpcodes([0xB0, 0x01, 0x80, 0xC0, 0x7F])
        immediate.run(maxSteps: 2)
        // MOV AL,0x01; MOV BL,0x7F; ADD AL,BL (00 D8).
        let registerForm = machineWithOpcodes([0xB0, 0x01, 0xB3, 0x7F, 0x00, 0xD8])
        registerForm.run(maxSteps: 3)
        #expect(immediate.snapshot().cpu.flags.rawValue == registerForm.snapshot().cpu.flags.rawValue)
        #expect(immediate.cpu.ax & 0xFF == registerForm.cpu.ax & 0xFF)
    }

    @Test("IP advances past ModR/M, displacement, and immediate")
    func ipAdvancesFullLength() {
        // 81 /0 with direct address: opcode + modrm + disp16 + imm16 = 6 bytes.
        let machine = machineWithOpcodes([0x81, 0x06, 0x00, 0x02, 0x01, 0x00])
        machine.step()
        #expect(machine.cpu.ip == 6)
    }

    @Test("Newly implemented carry-group ops consume their full encoding")
    func carryGroupOpAdvances() {
        // 80 /2 ADC AL,0xFF with carry clear, followed by HLT.
        let machine = machineWithOpcodes([0x80, 0xD0, 0xFF, 0xF4])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.registers[.al] == 0xFF)
        #expect(machine.cpu.halted) // IP landed exactly on the HLT
    }
}
