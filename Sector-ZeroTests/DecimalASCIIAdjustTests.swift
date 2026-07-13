import Testing
@testable import Sector_Zero

/// Milestone 36 — original-8086 decimal and ASCII adjust instructions.
struct DecimalASCIIAdjustTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    private func cpuWithAX(_ value: UInt16) -> CPU8086 {
        let cpu = Machine().cpu
        _ = cpu.execute(.movImmediateToRegister16(.ax, value))
        return cpu
    }

    private func set(_ flag: CPUFlag, to value: Bool, on cpu: CPU8086) {
        _ = cpu.execute(value ? .setFlag(flag) : .clearFlag(flag))
    }

    private func writeWord(_ value: UInt16, at address: UInt32, to machine: Machine) {
        machine.bus.writeByte(UInt8(truncatingIfNeeded: value), at: address)
        machine.bus.writeByte(UInt8(value >> 8), at: address + 1)
    }

    @Test("Adjust opcodes decode and AAM/AAD consume their encoded base")
    func decoding() {
        let decoder = InstructionDecoder()
        let forbiddenReader: () -> UInt8 = {
            Issue.record("Operand-free adjust instruction requested a byte")
            return 0
        }

        #expect(decoder.decode(opcode: 0x27, registers: RegisterFile(), nextByte: forbiddenReader) == .decimalAdjustAfterAddition)
        #expect(decoder.decode(opcode: 0x2F, registers: RegisterFile(), nextByte: forbiddenReader) == .decimalAdjustAfterSubtraction)
        #expect(decoder.decode(opcode: 0x37, registers: RegisterFile(), nextByte: forbiddenReader) == .asciiAdjustAfterAddition)
        #expect(decoder.decode(opcode: 0x3F, registers: RegisterFile(), nextByte: forbiddenReader) == .asciiAdjustAfterSubtraction)

        var aamBytes: [UInt8] = [16, 0xAA]
        #expect(decoder.decode(opcode: 0xD4, registers: RegisterFile()) { aamBytes.removeFirst() } == .asciiAdjustAfterMultiply(base: 16))
        #expect(aamBytes == [0xAA])

        var aadBytes: [UInt8] = [7, 0xBB]
        #expect(decoder.decode(opcode: 0xD5, registers: RegisterFile()) { aadBytes.removeFirst() } == .asciiAdjustBeforeDivision(base: 7))
        #expect(aadBytes == [0xBB])
    }

    @Test("DAA honors every AF/CF input combination")
    func decimalAdjustAdditionInputs() {
        let cases: [(af: Bool, cf: Bool, result: UInt8)] = [
            (false, false, 0x09),
            (true,  false, 0x0F),
            (false, true,  0x69),
            (true,  true,  0x6F),
        ]

        for testCase in cases {
            let cpu = cpuWithAX(0x5509)
            set(.auxiliaryCarry, to: testCase.af, on: cpu)
            set(.carry, to: testCase.cf, on: cpu)
            let clocks = cpu.execute(.decimalAdjustAfterAddition)

            #expect(cpu.registers[.al] == testCase.result)
            #expect(cpu.registers[.ah] == 0x55)
            #expect(cpu.flags[.auxiliaryCarry] == testCase.af)
            #expect(cpu.flags[.carry] == testCase.cf)
            #expect(clocks == 4)
        }

        // Intel-style packed BCD example: 35 + 48 = binary 7Dh, adjusted 83.
        let example = cpuWithAX(0x007D)
        _ = example.execute(.decimalAdjustAfterAddition)
        #expect(example.ax == 0x0083)
        #expect(example.flags[.sign])
        #expect(!example.flags[.zero])
        #expect(!example.flags[.parity])
    }

    @Test("DAS honors every AF/CF input combination")
    func decimalAdjustSubtractionInputs() {
        let cases: [(af: Bool, cf: Bool, result: UInt8)] = [
            (false, false, 0x09),
            (true,  false, 0x03),
            (false, true,  0xA9),
            (true,  true,  0xA3),
        ]

        for testCase in cases {
            let cpu = cpuWithAX(0x5509)
            set(.auxiliaryCarry, to: testCase.af, on: cpu)
            set(.carry, to: testCase.cf, on: cpu)
            let clocks = cpu.execute(.decimalAdjustAfterSubtraction)

            #expect(cpu.registers[.al] == testCase.result)
            #expect(cpu.registers[.ah] == 0x55)
            #expect(cpu.flags[.auxiliaryCarry] == testCase.af)
            #expect(cpu.flags[.carry] == testCase.cf)
            #expect(clocks == 4)
        }

        // Packed BCD 35 - 08 leaves binary 2Dh before adjustment.
        let example = cpuWithAX(0x002D)
        _ = example.execute(.decimalAdjustAfterSubtraction)
        #expect(example.ax == 0x0027)
    }

    @Test("AAA/AAS handle carry paths and retain original-8086 separate-byte behavior")
    func asciiAdditionAndSubtraction() {
        let noCarry = cpuWithAX(0x1209)
        let noCarryClocks = noCarry.execute(.asciiAdjustAfterAddition)
        #expect(noCarry.ax == 0x1209)
        #expect(!noCarry.flags[.auxiliaryCarry])
        #expect(!noCarry.flags[.carry])
        #expect(noCarryClocks == 4)

        let carry = cpuWithAX(0x120B)
        _ = carry.execute(.asciiAdjustAfterAddition)
        #expect(carry.ax == 0x1301)
        #expect(carry.flags[.auxiliaryCarry])
        #expect(carry.flags[.carry])

        let aaa8086Edge = cpuWithAX(0x12FF)
        _ = aaa8086Edge.execute(.asciiAdjustAfterAddition)
        #expect(aaa8086Edge.ax == 0x1305) // not later-x86 AX + 0106h => 1405h

        let borrow = cpuWithAX(0x12FC)
        _ = borrow.execute(.asciiAdjustAfterSubtraction)
        #expect(borrow.ax == 0x1106)
        #expect(borrow.flags[.auxiliaryCarry])
        #expect(borrow.flags[.carry])

        let noBorrow = cpuWithAX(0x1204)
        let noBorrowClocks = noBorrow.execute(.asciiAdjustAfterSubtraction)
        #expect(noBorrow.ax == 0x1204)
        #expect(!noBorrow.flags[.auxiliaryCarry])
        #expect(!noBorrow.flags[.carry])
        #expect(noBorrowClocks == 4)

        let aas8086Edge = cpuWithAX(0x1200)
        set(.auxiliaryCarry, to: true, on: aas8086Edge)
        _ = aas8086Edge.execute(.asciiAdjustAfterSubtraction)
        #expect(aas8086Edge.ax == 0x110A) // not later-x86 AX - 0106h => 100Ah
    }

    @Test("AAM/AAD use non-decimal bases and update only SF/ZF/PF")
    func arbitraryBasesAndFlags() {
        let aam = cpuWithAX(0xAA2F)
        set(.carry, to: true, on: aam)
        set(.auxiliaryCarry, to: true, on: aam)
        set(.overflow, to: true, on: aam)
        let aamClocks = aam.execute(.asciiAdjustAfterMultiply(base: 16))

        #expect(aam.ax == 0x020F)
        #expect(aam.flags[.carry])
        #expect(aam.flags[.auxiliaryCarry])
        #expect(aam.flags[.overflow])
        #expect(!aam.flags[.sign])
        #expect(!aam.flags[.zero])
        #expect(aam.flags[.parity])
        #expect(aamClocks == 83)

        let aad = cpuWithAX(0x020F)
        set(.carry, to: true, on: aad)
        set(.auxiliaryCarry, to: true, on: aad)
        set(.overflow, to: true, on: aad)
        let aadClocks = aad.execute(.asciiAdjustBeforeDivision(base: 16))

        #expect(aad.ax == 0x002F)
        #expect(aad.flags[.carry])
        #expect(aad.flags[.auxiliaryCarry])
        #expect(aad.flags[.overflow])
        #expect(!aad.flags[.sign])
        #expect(!aad.flags[.zero])
        #expect(!aad.flags[.parity])
        #expect(aadClocks == 60)
    }

    @Test("Undefined flags are preserved deterministically")
    func undefinedFlagsArePreserved() {
        let decimal = cpuWithAX(0x009A)
        set(.overflow, to: true, on: decimal)
        _ = decimal.execute(.decimalAdjustAfterAddition)
        #expect(decimal.registers[.al] == 0)
        #expect(decimal.flags[.overflow])
        #expect(decimal.flags[.zero])
        #expect(decimal.flags[.parity])

        let ascii = cpuWithAX(0x000B)
        for flag in [CPUFlag.overflow, .sign, .zero, .parity] {
            set(flag, to: true, on: ascii)
        }
        _ = ascii.execute(.asciiAdjustAfterAddition)
        #expect(ascii.flags[.overflow])
        #expect(ascii.flags[.sign])
        #expect(ascii.flags[.zero])
        #expect(ascii.flags[.parity])
    }

    @Test("AAM base zero enters vector 0 with AX intact and following IP saved")
    func aamZeroBaseDivideError() {
        // MOV SP,0100; MOV AX,1234; AAM 0.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0xB8, 0x34, 0x12,
            0xD4, 0x00,
        ])
        writeWord(0x5678, at: 0, to: machine)
        writeWord(0x2000, at: 2, to: machine)

        machine.run(maxSteps: 3)

        #expect(machine.cpu.cs == 0x2000)
        #expect(machine.cpu.ip == 0x5678)
        #expect(machine.cpu.ax == 0x1234)
        #expect(machine.cpu.sp == 0x00FA)
        #expect(machine.bus.readWord(at: 0x00FA) == 0x0008)
        #expect(machine.bus.readWord(at: 0x00FC) == 0xFFFF)
        #expect(machine.cpu.fault == nil)
        #expect(machine.cycleCount == 91) // MOV 4 + MOV 4 + AAM 83
    }
}
