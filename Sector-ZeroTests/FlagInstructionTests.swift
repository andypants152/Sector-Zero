import Testing
@testable import Sector_Zero

/// Milestone 23 — direct FLAGS access and one-byte flag manipulation.
struct FlagInstructionTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            let address = (resetVector + UInt32(offset)) & AddressTranslator.physicalAddressMask
            machine.bus.writeByte(opcode, at: address)
        }
        return machine
    }

    @Test("M23 opcodes decode without consuming operand bytes")
    func decodesFlagInstructions() {
        let decoder = InstructionDecoder()
        let forbiddenReader: () -> UInt8 = {
            Issue.record("Flag instruction unexpectedly requested an operand byte")
            return 0
        }

        #expect(decoder.decode(opcode: 0x9C, registers: RegisterFile(), nextByte: forbiddenReader) == .pushFlags)
        #expect(decoder.decode(opcode: 0x9D, registers: RegisterFile(), nextByte: forbiddenReader) == .popFlags)
        #expect(decoder.decode(opcode: 0x9E, registers: RegisterFile(), nextByte: forbiddenReader) == .storeAHIntoStatusFlags)
        #expect(decoder.decode(opcode: 0x9F, registers: RegisterFile(), nextByte: forbiddenReader) == .loadStatusFlagsIntoAH)
        #expect(decoder.decode(opcode: 0xF5, registers: RegisterFile(), nextByte: forbiddenReader) == .complementCarry)
        #expect(decoder.decode(opcode: 0xF8, registers: RegisterFile(), nextByte: forbiddenReader) == .clearFlag(.carry))
        #expect(decoder.decode(opcode: 0xF9, registers: RegisterFile(), nextByte: forbiddenReader) == .setFlag(.carry))
        #expect(decoder.decode(opcode: 0xFA, registers: RegisterFile(), nextByte: forbiddenReader) == .clearFlag(.interruptEnable))
        #expect(decoder.decode(opcode: 0xFB, registers: RegisterFile(), nextByte: forbiddenReader) == .setFlag(.interruptEnable))
        #expect(decoder.decode(opcode: 0xFC, registers: RegisterFile(), nextByte: forbiddenReader) == .clearFlag(.direction))
        #expect(decoder.decode(opcode: 0xFD, registers: RegisterFile(), nextByte: forbiddenReader) == .setFlag(.direction))
    }

    @Test("PUSHF writes the complete FLAGS word through SS:SP (10 clocks)")
    func pushFlags() {
        // MOV SP,0100; STC; STI; STD; PUSHF.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xF9, 0xFB, 0xFD, 0x9C])
        machine.cpu.writeSegment(0x2000, to: .ss)
        machine.run(maxSteps: 5)

        #expect(machine.cpu.sp == 0x00FE)
        #expect(machine.bus.readByte(at: 0x200FE) == 0x03)
        #expect(machine.bus.readByte(at: 0x200FF) == 0xF6)
        #expect(machine.cycleCount == 20) // MOV 4 + three flag ops 6 + PUSHF 10
    }

    @Test("POPF restores writable flags and normalizes all reserved bits")
    func popFlagsNormalizesReservedBits() {
        // MOV SP,0100; MOV AX,FFFF; PUSH AX; POPF.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0xB8, 0xFF, 0xFF,
            0x50,
            0x9D,
        ])
        machine.run(maxSteps: 4)

        // Bits 1 and 12–15 are fixed one; bits 3 and 5 are fixed zero.
        #expect(machine.cpu.flags.rawValue == 0xFFD7)
        #expect(machine.cpu.sp == 0x0100)
        #expect(machine.cycleCount == 27) // MOVs 8 + PUSH 11 + POPF 8
    }

    @Test("PUSHF then POPF round-trips condition and control flags")
    func pushPopFlagsRoundTrip() {
        // Seed every writable flag through POPF, save with PUSHF, clear via a
        // second POPF, then restore the saved word.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x02,             // MOV SP,0200
            0xB8, 0xD5, 0x0F, 0x50, 0x9D, // writable flags all set
            0x9C,                          // save FLAGS at 01FE
            0xB8, 0x00, 0x00, 0x50, 0x9D, // clear writable flags
            0x9D,                          // restore saved FLAGS
        ])
        machine.run(maxSteps: 9)

        #expect(machine.cpu.flags.rawValue == 0xFFD7)
        #expect(machine.cpu.sp == 0x0200)
    }

    @Test("LAHF writes the exact status-byte layout and preserves AL")
    func loadStatusFlagsIntoAH() {
        // POPF seeds SF/ZF/AF/PF/CF plus OF/DF/IF/TF, then LAHF.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0xB8, 0xD5, 0x0F,
            0x50, 0x9D,
            0x9F,
        ])
        machine.run(maxSteps: 5)

        #expect(machine.cpu.registers[.ah] == 0xD7) // S Z 0 A 0 P 1 C
        #expect(machine.cpu.registers[.al] == 0xD5)
        #expect(machine.cpu.flags[.overflow])
        #expect(machine.cpu.flags[.trap])
        #expect(machine.cpu.flags[.interruptEnable])
        #expect(machine.cpu.flags[.direction])
        #expect(machine.cycleCount == 31) // MOVs 8 + PUSH 11 + POPF 8 + LAHF 4
    }

    @Test("SAHF replaces only SF/ZF/AF/PF/CF and preserves control flags plus OF")
    func storeAHIntoStatusFlags() {
        // Seed every flag, load AH=0, then SAHF to clear only the five status
        // flags. MOV does not disturb the seeded control flags or OF.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0xB8, 0xFF, 0xFF,
            0x50, 0x9D,
            0xB8, 0x00, 0x00,
            0x9E,
        ])
        machine.run(maxSteps: 6)

        #expect(machine.cpu.flags.rawValue == 0xFF02)
        #expect(machine.cycleCount == 35) // MOVs 12 + PUSH 11 + POPF 8 + SAHF 4
    }

    @Test("CLC/STC/CMC manipulate only carry at 2 clocks each")
    func carryInstructions() {
        let machine = machineWithOpcodes([0xF8, 0xF5, 0xF9, 0xF5])
        machine.run(maxSteps: 4)

        #expect(!machine.cpu.flags[.carry])
        #expect(machine.cpu.flags.rawValue == 0xF002)
        #expect(machine.cycleCount == 8)
    }

    @Test("CLI/STI and CLD/STD store their control flags at 2 clocks each")
    func controlFlagInstructions() {
        let machine = machineWithOpcodes([0xFB, 0xFD, 0xFA, 0xFC])
        machine.run(maxSteps: 4)

        #expect(!machine.cpu.flags[.interruptEnable])
        #expect(!machine.cpu.flags[.direction])
        #expect(machine.cpu.flags.rawValue == 0xF002)
        #expect(machine.cycleCount == 8)
    }
}
