import Testing
@testable import Sector_Zero

/// Milestone 10 — ALU flag engine + ADD (0x00–0x03).
///
/// The ALU is pure and returns the result plus the six arithmetic flags:
/// CF = carry out; AF = carry out of bit 3; ZF/SF from the result;
/// PF = even parity of the low byte only; OF = signed overflow. ADD r/m↔reg
/// costs 3 clocks reg→reg, 16+EA when the destination is memory
/// (read-modify-write), 9+EA when the source is.
struct ALUAddTests {
    // MARK: 8-bit flag vectors

    @Test("0xFF + 1 = 0x00 sets CF, ZF, AF, PF; clears SF, OF")
    func byteCarryOut() {
        let (result, flags) = ALU.add8(0xFF, 0x01)
        #expect(result == 0x00)
        #expect(flags.carry)
        #expect(flags.zero)
        #expect(flags.auxiliaryCarry)
        #expect(flags.parity)
        #expect(!flags.sign)
        #expect(!flags.overflow)
    }

    @Test("0x7F + 1 = 0x80 sets OF, SF, AF; clears CF, ZF, PF")
    func byteSignedOverflow() {
        let (result, flags) = ALU.add8(0x7F, 0x01)
        #expect(result == 0x80)
        #expect(flags.overflow)
        #expect(flags.sign)
        #expect(flags.auxiliaryCarry)
        #expect(!flags.carry)
        #expect(!flags.zero)
        #expect(!flags.parity) // 0x80 has one set bit — odd
    }

    @Test("0x80 + 0x80 = 0x00: unsigned carry AND signed overflow")
    func byteNegativeOverflow() {
        let (result, flags) = ALU.add8(0x80, 0x80)
        #expect(result == 0x00)
        #expect(flags.carry)
        #expect(flags.overflow)
        #expect(flags.zero)
        #expect(!flags.auxiliaryCarry)
    }

    @Test("0x10 + 0x20 = 0x30: only PF set (two bits — even)")
    func byteNoCarries() {
        let (result, flags) = ALU.add8(0x10, 0x20)
        #expect(result == 0x30)
        #expect(!flags.carry)
        #expect(!flags.auxiliaryCarry)
        #expect(!flags.zero)
        #expect(!flags.sign)
        #expect(!flags.overflow)
        #expect(flags.parity)
    }

    @Test("0x08 + 0x08 sets AF from the bit-3 carry")
    func byteAuxiliaryCarry() {
        let (result, flags) = ALU.add8(0x08, 0x08)
        #expect(result == 0x10)
        #expect(flags.auxiliaryCarry)
        #expect(!flags.carry)
    }

    // MARK: 16-bit flag vectors

    @Test("0x8000 + 0x8000 = 0x0000: CF, OF, ZF, PF set; SF, AF clear")
    func wordCarryAndOverflow() {
        let (result, flags) = ALU.add16(0x8000, 0x8000)
        #expect(result == 0x0000)
        #expect(flags.carry)
        #expect(flags.overflow)
        #expect(flags.zero)
        #expect(flags.parity)
        #expect(!flags.sign)
        #expect(!flags.auxiliaryCarry)
    }

    @Test("0x0FFF + 1 carries out of bit 3 (AF) but not bit 15")
    func wordAuxiliaryCarry() {
        let (result, flags) = ALU.add16(0x0FFF, 0x0001)
        #expect(result == 0x1000)
        #expect(flags.auxiliaryCarry)
        #expect(!flags.carry)
        #expect(!flags.overflow)
    }

    @Test("PF reflects the low byte only")
    func parityIgnoresHighByte() {
        // 0x0100 has one set bit overall, but its low byte 0x00 is even parity.
        let (result, flags) = ALU.add16(0x00FF, 0x0001)
        #expect(result == 0x0100)
        #expect(flags.parity)

        // Low byte 0x01 — odd parity — even though the full word has two bits.
        let (result2, flags2) = ALU.add16(0x0100, 0x0001)
        #expect(result2 == 0x0101)
        #expect(!flags2.parity)
    }

    @Test("0x7FFF + 1 = 0x8000 sets OF and SF at word width")
    func wordSignedOverflow() {
        let (result, flags) = ALU.add16(0x7FFF, 0x0001)
        #expect(result == 0x8000)
        #expect(flags.overflow)
        #expect(flags.sign)
        #expect(flags.auxiliaryCarry)
        #expect(!flags.carry)
    }

    // MARK: End-to-end execution

    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    @Test("00: ADD r/m8, r8 register form adds into the r/m register")
    func addByteRegToReg() {
        // MOV AL, 3; MOV CL, 4; ADD AL, CL (00 C8).
        let machine = machineWithOpcodes([0xB0, 0x03, 0xB1, 0x04, 0x00, 0xC8])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.registers[.al] == 0x07)
        // 4 + 4 + 3 clocks.
        #expect(machine.snapshot().cycleCount == 11)
    }

    @Test("01: word ADD sets flags visible in the machine's FLAGS register")
    func addWordSetsFlags() {
        // MOV AX, 0xFFFF; MOV BX, 1; ADD AX, BX (01 D8).
        let machine = machineWithOpcodes([0xB8, 0xFF, 0xFF, 0xBB, 0x01, 0x00, 0x01, 0xD8])
        machine.run(maxSteps: 3)
        let flags = machine.snapshot().cpu.flags
        #expect(machine.cpu.ax == 0x0000)
        #expect(flags[.carry])
        #expect(flags[.zero])
        #expect(!flags[.overflow])
    }

    @Test("02: ADD r8, r/m8 reads the memory operand (9+EA cycles)")
    func addByteFromMemory() {
        // MOV AL, 0x10; ADD AL, [0x0040] (02 06 40 00).
        let machine = machineWithOpcodes([0xB0, 0x10, 0x02, 0x06, 0x40, 0x00])
        machine.bus.writeByte(0x22, at: 0x0040)
        machine.run(maxSteps: 2)
        #expect(machine.cpu.registers[.al] == 0x32)
        // MOV 4 + (ADD mem→reg 9 + direct EA 6).
        #expect(machine.snapshot().cycleCount == 19)
    }

    @Test("00 to memory is read-modify-write (16+EA cycles)")
    func addByteToMemory() {
        // MOV BL, 5; ADD [0x0060], BL (00 1E 60 00).
        let machine = machineWithOpcodes([0xB3, 0x05, 0x00, 0x1E, 0x60, 0x00])
        machine.bus.writeByte(0x0A, at: 0x0060)
        machine.run(maxSteps: 2)
        #expect(machine.bus.readByte(at: 0x0060) == 0x0F)
        #expect(machine.cpu.registers[.bl] == 0x05) // source untouched
        // MOV 4 + (ADD reg→mem 16 + direct EA 6).
        #expect(machine.snapshot().cycleCount == 26)
    }

    @Test("03: word ADD from memory is little-endian")
    func addWordFromMemory() {
        // MOV BX, 1; ADD BX, [0x0080] (03 1E 80 00).
        let machine = machineWithOpcodes([0xBB, 0x01, 0x00, 0x03, 0x1E, 0x80, 0x00])
        machine.bus.writeByte(0xFF, at: 0x0080)
        machine.bus.writeByte(0x00, at: 0x0081)
        machine.run(maxSteps: 2)
        #expect(machine.cpu.bx == 0x0100)
    }

    @Test("ADD leaves unrelated flags (IF, DF, TF) untouched")
    func addPreservesControlFlags() {
        let machine = machineWithOpcodes([0xB0, 0x01, 0x00, 0xC0]) // MOV AL,1; ADD AL,AL
        let before = machine.snapshot().cpu.flags
        machine.run(maxSteps: 2)
        let after = machine.snapshot().cpu.flags
        #expect(after[.interruptEnable] == before[.interruptEnable])
        #expect(after[.direction] == before[.direction])
        #expect(after[.trap] == before[.trap])
    }
}
