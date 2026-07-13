import Testing
@testable import Sector_Zero

/// Milestone 7 — MOV immediate → register (0xB0–0xBF).
///
/// 0xB0–0xB7 are MOV reg8, imm8; 0xB8–0xBF are MOV reg16, imm16 with the
/// immediate stored little-endian in the code stream. The low three opcode
/// bits are the register encoding. MOV affects no flags and costs 4 clocks
/// (register form). IP advances past the opcode plus its immediate.
struct MovImmediateTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            // Programs longer than 16 bytes run past the top of the 1 MB
            // space; wrap exactly as the fetch's physical address mask does.
            let address = (resetVector + UInt32(offset)) & AddressTranslator.physicalAddressMask
            machine.bus.writeByte(opcode, at: address)
        }
        return machine
    }

    // MARK: Decoding

    @Test("0xB0–0xB7 decode to 8-bit MOVs with the immediate from the stream",
          arguments: zip(UInt8(0xB0)...0xB7, Register8.allCases))
    func decodesByteMoves(opcode: UInt8, register: Register8) {
        let decoder = InstructionDecoder()
        var stream: [UInt8] = [0x42]
        let instruction = decoder.decode(opcode: opcode, registers: RegisterFile()) { stream.removeFirst() }
        #expect(instruction == .movImmediateToRegister8(register, 0x42))
        #expect(stream.isEmpty)
    }

    @Test("0xB8–0xBF decode to 16-bit MOVs, little-endian immediate",
          arguments: zip(UInt8(0xB8)...0xBF, Register16.allCases))
    func decodesWordMoves(opcode: UInt8, register: Register16) {
        let decoder = InstructionDecoder()
        var stream: [UInt8] = [0x34, 0x12]
        let instruction = decoder.decode(opcode: opcode, registers: RegisterFile()) { stream.removeFirst() }
        #expect(instruction == .movImmediateToRegister16(register, 0x1234))
        #expect(stream.isEmpty)
    }

    // MARK: Execution

    @Test("B0 42 loads AL and leaves AH untouched")
    func movToAL() {
        let machine = machineWithOpcodes([0xB0, 0x42])
        machine.step()
        let snapshot = machine.snapshot()
        #expect(snapshot.cpu.ax == 0x0042)
        #expect(snapshot.cpu.ip == 0x0002)
        #expect(snapshot.cycleCount == 4)
    }

    @Test("B4 99 loads AH and leaves AL untouched")
    func movToAH() {
        let machine = machineWithOpcodes([0xB0, 0x42, 0xB4, 0x99])
        machine.step()
        machine.step()
        #expect(machine.cpu.ax == 0x9942)
    }

    @Test("BB 34 12 loads BX little-endian")
    func movToBXLittleEndian() {
        let machine = machineWithOpcodes([0xBB, 0x34, 0x12])
        machine.step()
        let snapshot = machine.snapshot()
        #expect(snapshot.cpu.bx == 0x1234)
        #expect(snapshot.cpu.ip == 0x0003)
        #expect(snapshot.cycleCount == 4)
    }

    @Test("MOV affects no flags")
    func movLeavesFlagsUntouched() {
        let machine = machineWithOpcodes([0xB8, 0xFF, 0xFF])
        let before = machine.snapshot().cpu.flags.rawValue
        machine.step()
        #expect(machine.snapshot().cpu.flags.rawValue == before)
    }

    @Test("All eight 8-bit register encodings write the correct register")
    func allByteEncodings() {
        // B0..B7 in encoding order: AL,CL,DL,BL,AH,CH,DH,BH — distinct values.
        var program: [UInt8] = []
        for (index, _) in Register8.allCases.enumerated() {
            program += [0xB0 + UInt8(index), 0x10 + UInt8(index)]
        }
        let machine = machineWithOpcodes(program)
        machine.run(maxSteps: 8)

        for (index, register) in Register8.allCases.enumerated() {
            #expect(machine.cpu.registers[register] == 0x10 + UInt8(index))
        }
    }

    @Test("All eight 16-bit register encodings write the correct register")
    func allWordEncodings() {
        var program: [UInt8] = []
        for (index, _) in Register16.allCases.enumerated() {
            program += [0xB8 + UInt8(index), UInt8(index), 0xA0]
        }
        let machine = machineWithOpcodes(program)
        machine.run(maxSteps: 8)

        for (index, register) in Register16.allCases.enumerated() {
            #expect(machine.cpu.registers[register] == 0xA000 + UInt16(index))
        }
    }

    @Test("IP advances by total instruction length across a program")
    func ipAdvancesByInstructionLength() {
        let machine = machineWithOpcodes([0xB0, 0x01, 0xB8, 0x02, 0x00, 0x90])
        machine.step()
        #expect(machine.cpu.ip == 0x0002)
        machine.step()
        #expect(machine.cpu.ip == 0x0005)
        machine.step()
        #expect(machine.cpu.ip == 0x0006)
        #expect(machine.snapshot().cycleCount == 4 + 4 + 3)
    }
}
