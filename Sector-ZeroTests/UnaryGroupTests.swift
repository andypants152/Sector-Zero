import Testing
@testable import Sector_Zero

/// Milestone 26 — the 8086 F6/F7 unary arithmetic group. Undefined flags are
/// preserved deterministically, and divide errors halt with an observable
/// sentinel until interrupt vector 0 is implemented in M35.
struct UnaryGroupTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            let address = (resetVector + UInt32(offset)) & AddressTranslator.physicalAddressMask
            machine.bus.writeByte(opcode, at: address)
        }
        return machine
    }

    @Test("F6/F7 decode TEST and every defined unary selector")
    func decodesEverySelector() {
        let decoder = InstructionDecoder()

        var byteTestStream: [UInt8] = [0xC0, 0x5A]
        #expect(decoder.decode(opcode: 0xF6, registers: RegisterFile()) { byteTestStream.removeFirst() }
            == .testImmediateRM8(destination: .register(0), immediate: 0x5A, eaClocks: 0))

        var wordTestStream: [UInt8] = [0xC0, 0x34, 0x12]
        #expect(decoder.decode(opcode: 0xF7, registers: RegisterFile()) { wordTestStream.removeFirst() }
            == .testImmediateRM16(destination: .register(0), immediate: 0x1234, eaClocks: 0))

        for operation in [
            UnaryOperation.not, .negate, .multiplyUnsigned, .multiplySigned,
            .divideUnsigned, .divideSigned,
        ] {
            let modRM = UInt8(0xC0) | operation.rawValue << 3
            #expect(decoder.decode(opcode: 0xF6, registers: RegisterFile()) { modRM }
                == .unary8(operation: operation, operand: .register(0), eaClocks: 0))
            #expect(decoder.decode(opcode: 0xF7, registers: RegisterFile()) { modRM }
                == .unary16(operation: operation, operand: .register(0), eaClocks: 0))
        }
    }

    @Test("Undefined /1 consumes only ModR/M and displacement")
    func undefinedSelectorStaysAligned() {
        // F6 /1 direct-address consumes opcode+ModR/M+disp16, then HLT.
        let machine = machineWithOpcodes([0xF6, 0x0E, 0x40, 0x00, 0xF4])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ip == 5)
        #expect(machine.cpu.halted)
    }

    @Test("F6 /0 TEST matches TEST r/m8,reg8 flags and timing")
    func testImmediateMatchesRegisterForm() {
        // MOV AL,A5; MOV BL,0F; TEST AL,BL.
        let registerForm = machineWithOpcodes([0xB0, 0xA5, 0xB3, 0x0F, 0x84, 0xD8])
        registerForm.run(maxSteps: 3)

        // MOV AL,A5; TEST AL,0F.
        let immediateForm = machineWithOpcodes([0xB0, 0xA5, 0xF6, 0xC0, 0x0F])
        immediateForm.run(maxSteps: 2)

        #expect(immediateForm.cpu.registers[.al] == 0xA5)
        #expect(immediateForm.cpu.flags == registerForm.cpu.flags)
        #expect(immediateForm.cycleCount == 9) // MOV 4 + TEST reg,imm 5
    }

    @Test("NOT complements register and memory operands without touching flags")
    func notPreservesFlags() {
        // STC; MOV AL,55; NOT AL.
        let register = machineWithOpcodes([0xF9, 0xB0, 0x55, 0xF6, 0xD0])
        register.run(maxSteps: 3)
        #expect(register.cpu.registers[.al] == 0xAA)
        #expect(register.cpu.flags[.carry])
        #expect(register.cycleCount == 9)

        // NOT word [0040], direct-address EA is 6 clocks.
        let memory = machineWithOpcodes([0xF7, 0x16, 0x40, 0x00])
        memory.bus.writeByte(0x34, at: 0x0040)
        memory.bus.writeByte(0x12, at: 0x0041)
        let before = memory.cpu.flags
        memory.step()
        #expect(memory.bus.readByte(at: 0x0040) == 0xCB)
        #expect(memory.bus.readByte(at: 0x0041) == 0xED)
        #expect(memory.cpu.flags == before)
        #expect(memory.cycleCount == 22) // 16 + EA 6
    }

    @Test("NEG defines subtraction flags for zero and byte minimum")
    func negateByteEdges() {
        let zero = machineWithOpcodes([0xB0, 0x00, 0xF6, 0xD8])
        zero.run(maxSteps: 2)
        #expect(zero.cpu.registers[.al] == 0)
        #expect(!zero.cpu.flags[.carry])
        #expect(zero.cpu.flags[.zero])

        let minimum = machineWithOpcodes([0xB0, 0x80, 0xF6, 0xD8])
        minimum.run(maxSteps: 2)
        #expect(minimum.cpu.registers[.al] == 0x80)
        #expect(minimum.cpu.flags[.carry])
        #expect(minimum.cpu.flags[.overflow])
        #expect(minimum.cpu.flags[.sign])
    }

    @Test("NEG word minimum is unchanged and sets OF/CF")
    func negateWordMinimum() {
        let machine = machineWithOpcodes([0xB8, 0x00, 0x80, 0xF7, 0xD8])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.registers[.ax] == 0x8000)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cpu.flags[.overflow])
    }

    @Test("MUL writes double-width byte and word products and CF=OF")
    func multiplyUnsigned() {
        // 10h × 10h = 0100h, so AH is significant.
        let byte = machineWithOpcodes([0xB0, 0x10, 0xB3, 0x10, 0xF6, 0xE3])
        byte.run(maxSteps: 3)
        #expect(byte.cpu.registers[.ax] == 0x0100)
        #expect(byte.cpu.flags[.carry])
        #expect(byte.cpu.flags[.overflow])
        #expect(byte.cycleCount == 82) // MOVs 8 + midpoint MUL 74

        // FFFFh × 2 = 0001:FFFEh.
        let word = machineWithOpcodes([0xB8, 0xFF, 0xFF, 0xBB, 0x02, 0x00, 0xF7, 0xE3])
        word.run(maxSteps: 3)
        #expect(word.cpu.registers[.ax] == 0xFFFE)
        #expect(word.cpu.registers[.dx] == 0x0001)
        #expect(word.cpu.flags[.carry])
        #expect(word.cpu.flags[.overflow])
    }

    @Test("IMUL detects whether the high half is only sign extension")
    func multiplySigned() {
        // -2 × 3 = -6, which fits in signed byte: CF=OF=0.
        let byte = machineWithOpcodes([0xB0, 0xFE, 0xB3, 0x03, 0xF6, 0xEB])
        byte.run(maxSteps: 3)
        #expect(byte.cpu.registers[.ax] == 0xFFFA)
        #expect(!byte.cpu.flags[.carry])
        #expect(!byte.cpu.flags[.overflow])

        // 4000h × 2 = 0000:8000h, outside signed word range.
        let word = machineWithOpcodes([0xB8, 0x00, 0x40, 0xBB, 0x02, 0x00, 0xF7, 0xEB])
        word.run(maxSteps: 3)
        #expect(word.cpu.registers[.ax] == 0x8000)
        #expect(word.cpu.registers[.dx] == 0x0000)
        #expect(word.cpu.flags[.carry])
        #expect(word.cpu.flags[.overflow])
    }

    @Test("DIV returns unsigned quotient and remainder for both widths")
    func divideUnsigned() {
        // 0105h / 10h = quotient 10h, remainder 05h.
        let byte = machineWithOpcodes([0xB8, 0x05, 0x01, 0xB3, 0x10, 0xF6, 0xF3])
        byte.run(maxSteps: 3)
        #expect(byte.cpu.registers[.al] == 0x10)
        #expect(byte.cpu.registers[.ah] == 0x05)

        // 0001:0000h / 3 = 5555h remainder 1.
        let word = machineWithOpcodes([
            0xB8, 0x00, 0x00, 0xBA, 0x01, 0x00,
            0xBB, 0x03, 0x00, 0xF7, 0xF3,
        ])
        word.run(maxSteps: 4)
        #expect(word.cpu.registers[.ax] == 0x5555)
        #expect(word.cpu.registers[.dx] == 0x0001)
    }

    @Test("IDIV truncates toward zero and remainder follows dividend sign")
    func divideSigned() {
        // -7 / 3 = -2 remainder -1.
        let byte = machineWithOpcodes([0xB8, 0xF9, 0xFF, 0xB3, 0x03, 0xF6, 0xFB])
        byte.run(maxSteps: 3)
        #expect(byte.cpu.registers[.al] == 0xFE)
        #expect(byte.cpu.registers[.ah] == 0xFF)

        let word = machineWithOpcodes([
            0xB8, 0xF9, 0xFF, 0xBA, 0xFF, 0xFF,
            0xBB, 0x03, 0x00, 0xF7, 0xFB,
        ])
        word.run(maxSteps: 4)
        #expect(word.cpu.registers[.ax] == 0xFFFE)
        #expect(word.cpu.registers[.dx] == 0xFFFF)
    }

    @Test("Divide by zero halts with a divide-error sentinel and preserves operands")
    func divideByZeroFault() {
        let machine = machineWithOpcodes([0xB8, 0x34, 0x12, 0xB3, 0x00, 0xF6, 0xF3])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.registers[.ax] == 0x1234)
        #expect(machine.cpu.registers[.bl] == 0)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.fault == .divideError)
        #expect(machine.snapshot().cpu.fault == .divideError)

        machine.reset()
        #expect(!machine.cpu.halted)
        #expect(machine.cpu.fault == nil)
    }

    @Test("Unsigned quotient overflow raises divide error without partial writes")
    func quotientOverflowFault() {
        // 0100h / 1 cannot fit in AL.
        let machine = machineWithOpcodes([0xB8, 0x00, 0x01, 0xB3, 0x01, 0xF6, 0xF3])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.registers[.ax] == 0x0100)
        #expect(machine.cpu.fault == .divideError)
    }

    @Test("Original 8086 IDIV faults on its most-negative quotient")
    func mostNegativeSignedQuotientFault() {
        // -128 / 1 is representable in Int8, but original 8086 silicon faults.
        let machine = machineWithOpcodes([0xB8, 0x80, 0xFF, 0xB3, 0x01, 0xF6, 0xFB])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.registers[.ax] == 0xFF80)
        #expect(machine.cpu.fault == .divideError)
    }

    @Test("Memory MUL honors segment override and midpoint timing")
    func memoryMultiplyHonorsOverride() {
        // MOV AL,2; ES: MUL byte [0040].
        let machine = machineWithOpcodes([0xB0, 0x02, 0x26, 0xF6, 0x26, 0x40, 0x00])
        machine.cpu.writeSegment(0x2000, to: .es)
        machine.bus.writeByte(0x04, at: 0x20040)
        machine.bus.writeByte(0x09, at: 0x00040)
        machine.run(maxSteps: 2)
        #expect(machine.cpu.registers[.ax] == 0x0008)
        #expect(machine.cycleCount == 92) // MOV 4 + prefix 2 + (80 + EA 6)
    }
}
