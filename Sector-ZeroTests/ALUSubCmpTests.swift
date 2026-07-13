import Testing
@testable import Sector_Zero

/// Milestone 11 — SUB (0x28–0x2B) and CMP (0x38–0x3B).
///
/// Subtraction flags: CF = borrow; AF = borrow into bit 3; OF = signed
/// overflow of minuend−subtrahend; ZF/SF/PF as usual (PF low byte only).
/// CMP computes exactly like SUB but discards the result — flags only.
struct ALUSubCmpTests {
    // MARK: 8-bit subtract vectors

    @Test("0x00 - 1 = 0xFF sets CF, AF, SF, PF; clears ZF, OF")
    func byteBorrow() {
        let (result, flags) = ALU.subtract8(0x00, 0x01)
        #expect(result == 0xFF)
        #expect(flags.carry)
        #expect(flags.auxiliaryCarry)
        #expect(flags.sign)
        #expect(flags.parity) // 0xFF: eight bits — even
        #expect(!flags.zero)
        #expect(!flags.overflow)
    }

    @Test("0x80 - 1 = 0x7F sets OF and AF; clears CF, SF")
    func byteSignedOverflow() {
        let (result, flags) = ALU.subtract8(0x80, 0x01)
        #expect(result == 0x7F)
        #expect(flags.overflow)
        #expect(flags.auxiliaryCarry)
        #expect(!flags.carry)
        #expect(!flags.sign)
        #expect(!flags.parity) // 0x7F: seven bits — odd
    }

    @Test("Equal operands: ZF and PF set, everything else clear")
    func byteEqual() {
        let (result, flags) = ALU.subtract8(0x42, 0x42)
        #expect(result == 0x00)
        #expect(flags.zero)
        #expect(flags.parity)
        #expect(!flags.carry)
        #expect(!flags.auxiliaryCarry)
        #expect(!flags.sign)
        #expect(!flags.overflow)
    }

    @Test("0x10 - 0x01 borrows into bit 3 (AF) without CF")
    func byteAuxBorrow() {
        let (result, flags) = ALU.subtract8(0x10, 0x01)
        #expect(result == 0x0F)
        #expect(flags.auxiliaryCarry)
        #expect(!flags.carry)
    }

    // MARK: 16-bit subtract vectors

    @Test("0x0000 - 1 = 0xFFFF at word width")
    func wordBorrow() {
        let (result, flags) = ALU.subtract16(0x0000, 0x0001)
        #expect(result == 0xFFFF)
        #expect(flags.carry)
        #expect(flags.sign)
        #expect(flags.parity)
        #expect(!flags.overflow)
    }

    @Test("0x8000 - 1 = 0x7FFF sets OF at word width")
    func wordSignedOverflow() {
        let (result, flags) = ALU.subtract16(0x8000, 0x0001)
        #expect(result == 0x7FFF)
        #expect(flags.overflow)
        #expect(!flags.carry)
        #expect(!flags.sign)
    }

    @Test("Word PF still reflects the low byte only")
    func wordParityLowByte() {
        // 0x0200 - 0x0100 = 0x0100: low byte 0x00 → PF set.
        let (result, flags) = ALU.subtract16(0x0200, 0x0100)
        #expect(result == 0x0100)
        #expect(flags.parity)
    }

    // MARK: End-to-end execution

    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            let address = (resetVector + UInt32(offset)) & AddressTranslator.physicalAddressMask
            machine.bus.writeByte(opcode, at: address)
        }
        return machine
    }

    @Test("28: SUB r/m8, r8 register form subtracts and costs 3 clocks")
    func subByteRegToReg() {
        // MOV AL, 9; MOV CL, 3; SUB AL, CL (28 C8).
        let machine = machineWithOpcodes([0xB0, 0x09, 0xB1, 0x03, 0x28, 0xC8])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.registers[.al] == 0x06)
        #expect(machine.snapshot().cycleCount == 11)
    }

    @Test("29: SUB writes the result to memory (16+EA cycles)")
    func subWordToMemory() {
        // MOV CX, 0x0100; SUB [0x0070], CX (29 0E 70 00).
        let machine = machineWithOpcodes([0xB9, 0x00, 0x01, 0x29, 0x0E, 0x70, 0x00])
        machine.bus.writeByte(0x50, at: 0x0070) // word 0x0350
        machine.bus.writeByte(0x03, at: 0x0071)
        machine.run(maxSteps: 2)
        #expect(machine.bus.readByte(at: 0x0070) == 0x50)
        #expect(machine.bus.readByte(at: 0x0071) == 0x02) // 0x0350-0x0100 = 0x0250
        #expect(machine.snapshot().cycleCount == 4 + 16 + 6)
    }

    @Test("2B: SUB r16, r/m16 reads memory and sets borrow flags")
    func subWordFromMemory() {
        // MOV BX, 0; SUB BX, [0x0090] (2B 1E 90 00) with [0x0090] = 1.
        let machine = machineWithOpcodes([0xBB, 0x00, 0x00, 0x2B, 0x1E, 0x90, 0x00])
        machine.bus.writeByte(0x01, at: 0x0090)
        machine.run(maxSteps: 2)
        #expect(machine.cpu.bx == 0xFFFF)
        #expect(machine.snapshot().cpu.flags[.carry])
        #expect(machine.snapshot().cpu.flags[.sign])
    }

    @Test("38: CMP sets flags but writes nothing to the r/m register")
    func cmpRegistersOnlyFlags() {
        // MOV AL, 5; MOV CL, 5; CMP AL, CL (38 C8).
        let machine = machineWithOpcodes([0xB0, 0x05, 0xB1, 0x05, 0x38, 0xC8])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.registers[.al] == 0x05)
        #expect(machine.cpu.registers[.cl] == 0x05)
        #expect(machine.snapshot().cpu.flags[.zero])
        // CMP reg,reg is 3 clocks like SUB.
        #expect(machine.snapshot().cycleCount == 11)
    }

    @Test("39: CMP against memory leaves the memory untouched (9+EA cycles)")
    func cmpMemoryUntouched() {
        // MOV DX, 0x1234; CMP [0x00A0], DX (39 16 A0 00).
        let machine = machineWithOpcodes([0xBA, 0x34, 0x12, 0x39, 0x16, 0xA0, 0x00])
        machine.bus.writeByte(0x34, at: 0x00A0)
        machine.bus.writeByte(0x12, at: 0x00A1)
        machine.run(maxSteps: 2)
        #expect(machine.bus.readByte(at: 0x00A0) == 0x34)
        #expect(machine.bus.readByte(at: 0x00A1) == 0x12)
        #expect(machine.snapshot().cpu.flags[.zero])
        // CMP never writes, so r/m-destination memory form is 9+EA, not 16+EA.
        #expect(machine.snapshot().cycleCount == 4 + 9 + 6)
    }

    @Test("3B: CMP r16, r/m16 — below sets CF, above clears it")
    func cmpBelowAbove() {
        // MOV AX, 1; CMP AX, [0x00B0] with [0x00B0] = 2 → CF (below).
        let machine = machineWithOpcodes([0xB8, 0x01, 0x00, 0x3B, 0x06, 0xB0, 0x00])
        machine.bus.writeByte(0x02, at: 0x00B0)
        machine.run(maxSteps: 2)
        #expect(machine.snapshot().cpu.flags[.carry])
        #expect(machine.cpu.ax == 0x0001) // destination untouched

        // MOV AX, 3; CMP AX, [0x00B0] → no CF, no ZF (above).
        let machine2 = machineWithOpcodes([0xB8, 0x03, 0x00, 0x3B, 0x06, 0xB0, 0x00])
        machine2.bus.writeByte(0x02, at: 0x00B0)
        machine2.run(maxSteps: 2)
        #expect(!machine2.snapshot().cpu.flags[.carry])
        #expect(!machine2.snapshot().cpu.flags[.zero])
    }
}
