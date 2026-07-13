import Testing
@testable import Sector_Zero

/// Milestone 9 — MOV r/m ↔ reg (0x88–0x8B).
///
/// The first instructions to consume the ModR/M machinery. `88`/`89` move
/// reg → r/m (byte/word); `8A`/`8B` move r/m → reg. Memory operands resolve
/// through the actual DS/SS values (BP-based modes default to SS), words are
/// little-endian, and MOV touches no flags. Cycles: reg→reg 2; reg→mem 9+EA;
/// mem→reg 8+EA (direct address EA = 6 clocks).
struct MovRMTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    // MARK: Register ↔ register

    @Test("88: MOV r/m8, r8 register form copies the byte (AL ← CL)")
    func movByteRegToReg() {
        // MOV CL, 0x5A; MOV AL, CL (88 C8: mod=11 reg=CL rm=AL).
        let machine = machineWithOpcodes([0xB1, 0x5A, 0x88, 0xC8])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.registers[.al] == 0x5A)
        #expect(machine.cpu.registers[.cl] == 0x5A)
        // MOV imm (4) + MOV reg→reg (2).
        #expect(machine.snapshot().cycleCount == 6)
    }

    @Test("89: MOV r/m16, r16 register form copies the word (DX ← BX)")
    func movWordRegToReg() {
        // MOV BX, 0xBEEF; MOV DX, BX (89 DA: mod=11 reg=BX rm=DX).
        let machine = machineWithOpcodes([0xBB, 0xEF, 0xBE, 0x89, 0xDA])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.dx == 0xBEEF)
        #expect(machine.cpu.bx == 0xBEEF)
    }

    @Test("8A/8B reverse direction: reg ← r/m register form")
    func movRegFromRegisterOperand() {
        // MOV DX, 0x1234; MOV AX, DX via 8B C2 (mod=11 reg=AX rm=DX).
        let machine = machineWithOpcodes([0xBA, 0x34, 0x12, 0x8B, 0xC2])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax == 0x1234)
    }

    // MARK: Memory operands through DS

    @Test("8B with direct address reads a little-endian word from DS:addr")
    func movWordFromMemory() {
        let machine = machineWithOpcodes([0x8B, 0x1E, 0x34, 0x12]) // MOV BX, [0x1234]
        machine.cpu.writeSegment(0x1000, to: .ds)
        machine.bus.writeByte(0xCD, at: 0x11234) // 0x1000<<4 + 0x1234
        machine.bus.writeByte(0xAB, at: 0x11235)
        machine.step()
        let snapshot = machine.snapshot()
        #expect(snapshot.cpu.bx == 0xABCD)
        #expect(snapshot.cpu.ip == 0x0004)
        // mem→reg 8 + direct-address EA 6.
        #expect(snapshot.cycleCount == 14)
    }

    @Test("89 with direct address writes the register word to DS:addr")
    func movWordToMemory() {
        // MOV CX, 0x55AA; MOV [0x0080], CX (89 0E 80 00).
        let machine = machineWithOpcodes([0xB9, 0xAA, 0x55, 0x89, 0x0E, 0x80, 0x00])
        machine.cpu.writeSegment(0x2000, to: .ds)
        machine.run(maxSteps: 2)
        #expect(machine.bus.readByte(at: 0x20080) == 0xAA) // little-endian
        #expect(machine.bus.readByte(at: 0x20081) == 0x55)
        // MOV imm 4 + (reg→mem 9 + EA 6).
        #expect(machine.snapshot().cycleCount == 19)
    }

    @Test("88 writes a single byte to memory without touching its neighbour")
    func movByteToMemory() {
        // MOV AH, 0x7E; MOV [0x0040], AH (88 26 40 00).
        let machine = machineWithOpcodes([0xB4, 0x7E, 0x88, 0x26, 0x40, 0x00])
        machine.bus.writeByte(0x99, at: 0x0041)
        machine.run(maxSteps: 2)
        #expect(machine.bus.readByte(at: 0x0040) == 0x7E)
        #expect(machine.bus.readByte(at: 0x0041) == 0x99)
    }

    @Test("8A reads a byte through a BX+SI effective address")
    func movByteFromIndexedMemory() {
        // MOV BX, 0x0100; MOV SI, 0x0020; MOV DL, [BX+SI] (8A 10).
        let machine = machineWithOpcodes([0xBB, 0x00, 0x01, 0xBE, 0x20, 0x00, 0x8A, 0x10])
        machine.bus.writeByte(0x42, at: 0x0120) // DS=0 → physical 0x0120
        machine.run(maxSteps: 3)
        #expect(machine.cpu.registers[.dl] == 0x42)
    }

    // MARK: BP-based addressing uses SS

    @Test("BP+disp8 operand resolves through SS, not DS")
    func bpOperandUsesSS() {
        // MOV BP, 0x0100; MOV AL, [BP+0x10] (8A 46 10).
        let machine = machineWithOpcodes([0xBD, 0x00, 0x01, 0x8A, 0x46, 0x10])
        machine.cpu.writeSegment(0x3000, to: .ss)
        machine.cpu.writeSegment(0x1000, to: .ds)
        machine.bus.writeByte(0xEE, at: 0x30110) // SS:0x0110
        machine.bus.writeByte(0x11, at: 0x11110) // DS:0x0110 decoy
        machine.run(maxSteps: 2)
        #expect(machine.cpu.registers[.al] == 0xEE)
    }

    // MARK: Flags and lengths

    @Test("MOV r/m forms affect no flags")
    func movLeavesFlagsUntouched() {
        let machine = machineWithOpcodes([0xB8, 0xFF, 0xFF, 0x89, 0xC3]) // MOV AX,0xFFFF; MOV BX,AX
        let before = machine.snapshot().cpu.flags.rawValue
        machine.run(maxSteps: 2)
        #expect(machine.snapshot().cpu.flags.rawValue == before)
    }

    @Test("IP advances past opcode, ModR/M and displacement")
    func ipAdvancesPastFullInstruction() {
        // 8A 46 10 = 3 bytes (opcode + modrm + disp8).
        let machine = machineWithOpcodes([0x8A, 0x46, 0x10])
        machine.step()
        #expect(machine.cpu.ip == 0x0003)
    }

    // MARK: Segment write hook

    @Test("writeSegment sets each segment register")
    func writeSegmentSetsValues() {
        let machine = Machine()
        machine.cpu.writeSegment(0x1111, to: .es)
        machine.cpu.writeSegment(0x2222, to: .ss)
        machine.cpu.writeSegment(0x3333, to: .ds)
        #expect(machine.cpu.es == 0x1111)
        #expect(machine.cpu.ss == 0x2222)
        #expect(machine.cpu.ds == 0x3333)
    }
}
