import Testing
@testable import Sector_Zero

/// Milestone 24 — ADC and SBB across register, memory, immediate-group, and
/// accumulator encodings. CF is the carry/borrow input as well as the output.
struct CarryALUTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            let address = (resetVector + UInt32(offset)) & AddressTranslator.physicalAddressMask
            machine.bus.writeByte(opcode, at: address)
        }
        return machine
    }

    @Test("ADC includes carry-in in CF, AF, ZF, and PF")
    func adcCarryInFlags() {
        let (result, flags) = ALU.addWithCarry8(0xFF, 0x00, carryIn: true)
        #expect(result == 0x00)
        #expect(flags.carry)
        #expect(flags.auxiliaryCarry)
        #expect(flags.zero)
        #expect(flags.parity)
        #expect(!flags.sign)
        #expect(!flags.overflow)
    }

    @Test("ADC carry-in participates in signed overflow")
    func adcCarryInOverflow() {
        let byte = ALU.addWithCarry8(0x7F, 0x00, carryIn: true)
        #expect(byte.result == 0x80)
        #expect(byte.flags.overflow)
        #expect(byte.flags.auxiliaryCarry)
        #expect(!byte.flags.carry)

        let word = ALU.addWithCarry16(0x7FFF, 0x0000, carryIn: true)
        #expect(word.result == 0x8000)
        #expect(word.flags.overflow)
        #expect(!word.flags.carry)
    }

    @Test("SBB includes borrow-in in CF, AF, SF, and PF")
    func sbbBorrowInFlags() {
        let (result, flags) = ALU.subtractWithBorrow8(0x00, 0x00, borrowIn: true)
        #expect(result == 0xFF)
        #expect(flags.carry)
        #expect(flags.auxiliaryCarry)
        #expect(flags.sign)
        #expect(flags.parity)
        #expect(!flags.zero)
        #expect(!flags.overflow)
    }

    @Test("SBB borrow-in participates in signed overflow")
    func sbbBorrowInOverflow() {
        let byte = ALU.subtractWithBorrow8(0x80, 0x7F, borrowIn: true)
        #expect(byte.result == 0x00)
        #expect(byte.flags.overflow)
        #expect(byte.flags.auxiliaryCarry)
        #expect(!byte.flags.carry)

        let word = ALU.subtractWithBorrow16(0x8000, 0x7FFF, borrowIn: true)
        #expect(word.result == 0x0000)
        #expect(word.flags.overflow)
        #expect(!word.flags.carry)
    }

    @Test("Carry/borrow clear exactly matches ADD/SUB")
    func clearInputMatchesBaseOperations() {
        #expect(ALU.addWithCarry8(0xA5, 0x6B, carryIn: false) == ALU.add8(0xA5, 0x6B))
        #expect(ALU.addWithCarry16(0xA55A, 0x6BB6, carryIn: false) == ALU.add16(0xA55A, 0x6BB6))
        #expect(ALU.subtractWithBorrow8(0x10, 0x21, borrowIn: false) == ALU.subtract8(0x10, 0x21))
        #expect(ALU.subtractWithBorrow16(0x1000, 0x2001, borrowIn: false) == ALU.subtract16(0x1000, 0x2001))
    }

    @Test("ADD+ADC composes a 32-bit addition")
    func composed32BitAddition() {
        // DX:AX=0001:FFFF + CX:BX=0000:0001.
        let machine = machineWithOpcodes([
            0xB8, 0xFF, 0xFF, // MOV AX,FFFF
            0xBA, 0x01, 0x00, // MOV DX,0001
            0xBB, 0x01, 0x00, // MOV BX,0001
            0xB9, 0x00, 0x00, // MOV CX,0000
            0x01, 0xD8,       // ADD AX,BX
            0x11, 0xCA,       // ADC DX,CX
        ])
        machine.run(maxSteps: 6)

        #expect(machine.cpu.dx == 0x0002)
        #expect(machine.cpu.ax == 0x0000)
        #expect(!machine.cpu.flags[.carry])
        #expect(machine.cycleCount == 22)
    }

    @Test("SUB+SBB composes a 32-bit subtraction")
    func composed32BitSubtraction() {
        // DX:AX=0002:0000 - CX:BX=0000:0001.
        let machine = machineWithOpcodes([
            0xB8, 0x00, 0x00, // MOV AX,0000
            0xBA, 0x02, 0x00, // MOV DX,0002
            0xBB, 0x01, 0x00, // MOV BX,0001
            0xB9, 0x00, 0x00, // MOV CX,0000
            0x29, 0xD8,       // SUB AX,BX
            0x19, 0xCA,       // SBB DX,CX
        ])
        machine.run(maxSteps: 6)

        #expect(machine.cpu.dx == 0x0001)
        #expect(machine.cpu.ax == 0xFFFF)
        #expect(!machine.cpu.flags[.carry])
        #expect(machine.cycleCount == 22)
    }

    @Test("14/15 and 1C/1D accumulator shortcuts consume carry")
    func accumulatorImmediateForms() {
        // MOV AL,7F; STC; ADC AL,0 => 80 with signed overflow.
        let adc = machineWithOpcodes([0xB0, 0x7F, 0xF9, 0x14, 0x00])
        adc.run(maxSteps: 3)
        #expect(adc.cpu.registers[.al] == 0x80)
        #expect(adc.cpu.flags[.overflow])
        #expect(adc.cycleCount == 10)

        // MOV AX,8000; STC; SBB AX,7FFF => 0000 with signed overflow.
        let sbb = machineWithOpcodes([0xB8, 0x00, 0x80, 0xF9, 0x1D, 0xFF, 0x7F])
        sbb.run(maxSteps: 3)
        #expect(sbb.cpu.ax == 0x0000)
        #expect(sbb.cpu.flags[.overflow])
        #expect(sbb.cycleCount == 10)
    }

    @Test("80 /2 and /3 match accumulator ADC/SBB forms")
    func immediateGroupParity() {
        let adcAccumulator = machineWithOpcodes([0xB0, 0xFF, 0xF9, 0x14, 0x00])
        adcAccumulator.run(maxSteps: 3)
        let adcGroup = machineWithOpcodes([0xB0, 0xFF, 0xF9, 0x80, 0xD0, 0x00])
        adcGroup.run(maxSteps: 3)
        #expect(adcGroup.cpu.registers[.al] == adcAccumulator.cpu.registers[.al])
        #expect(adcGroup.cpu.flags == adcAccumulator.cpu.flags)

        let sbbAccumulator = machineWithOpcodes([0xB0, 0x00, 0xF9, 0x1C, 0x00])
        sbbAccumulator.run(maxSteps: 3)
        let sbbGroup = machineWithOpcodes([0xB0, 0x00, 0xF9, 0x80, 0xD8, 0x00])
        sbbGroup.run(maxSteps: 3)
        #expect(sbbGroup.cpu.registers[.al] == sbbAccumulator.cpu.registers[.al])
        #expect(sbbGroup.cpu.flags == sbbAccumulator.cpu.flags)
    }

    @Test("ADC memory destination is read-modify-write with ADD timing")
    func adcMemoryDestination() {
        // STC; ADC byte [0040],0. Direct-address EA is 6 clocks.
        let machine = machineWithOpcodes([0xF9, 0x80, 0x16, 0x40, 0x00, 0x00])
        machine.bus.writeByte(0xFF, at: 0x0040)
        machine.run(maxSteps: 2)

        #expect(machine.bus.readByte(at: 0x0040) == 0x00)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cycleCount == 25) // STC 2 + ADC 17+EA 6
    }

    @Test("ADC/SBB r/m↔register opcode blocks decode all directions and widths")
    func registerBlockDecoding() {
        let decoder = InstructionDecoder()
        let vectors: [(UInt8, Instruction)] = [
            (0x10, .aluRegisterToRM8(op: .adc, source: .cl, destination: .register(0), eaClocks: 0)),
            (0x11, .aluRegisterToRM16(op: .adc, source: .cx, destination: .register(0), eaClocks: 0)),
            (0x12, .aluRMToRegister8(op: .adc, destination: .cl, source: .register(0), eaClocks: 0)),
            (0x13, .aluRMToRegister16(op: .adc, destination: .cx, source: .register(0), eaClocks: 0)),
            (0x18, .aluRegisterToRM8(op: .sbb, source: .cl, destination: .register(0), eaClocks: 0)),
            (0x19, .aluRegisterToRM16(op: .sbb, source: .cx, destination: .register(0), eaClocks: 0)),
            (0x1A, .aluRMToRegister8(op: .sbb, destination: .cl, source: .register(0), eaClocks: 0)),
            (0x1B, .aluRMToRegister16(op: .sbb, destination: .cx, source: .register(0), eaClocks: 0)),
        ]
        for (opcode, expected) in vectors {
            #expect(decoder.decode(opcode: opcode, registers: RegisterFile()) { 0xC8 } == expected)
        }
    }
}
