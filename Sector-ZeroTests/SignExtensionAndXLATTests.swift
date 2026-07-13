import Testing
@testable import Sector_Zero

/// Milestone 37 — sign extension and XLAT table lookup.
struct SignExtensionAndXLATTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            machine.bus.writeByte(
                opcode,
                at: (resetVector + UInt32(offset)) & AddressTranslator.physicalAddressMask
            )
        }
        return machine
    }

    private func cpuWithAX(_ value: UInt16) -> CPU8086 {
        let cpu = Machine().cpu
        _ = cpu.execute(.movImmediateToRegister16(.ax, value))
        return cpu
    }

    private func setAllFlags(on cpu: CPU8086) {
        for flag in CPUFlag.allCases {
            _ = cpu.execute(.setFlag(flag))
        }
    }

    @Test("98, 99, and D7 decode without operand bytes")
    func decoding() {
        let decoder = InstructionDecoder()
        let forbiddenReader: () -> UInt8 = {
            Issue.record("Operand-free M37 instruction requested a byte")
            return 0
        }

        #expect(decoder.decode(opcode: 0x98, registers: RegisterFile(), nextByte: forbiddenReader) == .convertByteToWord)
        #expect(decoder.decode(opcode: 0x99, registers: RegisterFile(), nextByte: forbiddenReader) == .convertWordToDoubleword)
        #expect(decoder.decode(opcode: 0xD7, registers: RegisterFile(), nextByte: forbiddenReader) == .translateByte)
    }

    @Test("CBW sign-extends AL across positive, negative, and boundary values")
    func convertByteToWord() {
        let cases: [(input: UInt16, expected: UInt16)] = [
            (0xAB00, 0x0000),
            (0xAB7F, 0x007F),
            (0xAB80, 0xFF80),
            (0xABFF, 0xFFFF),
        ]

        for testCase in cases {
            let cpu = cpuWithAX(testCase.input)
            setAllFlags(on: cpu)
            let flagsBefore = cpu.flags.rawValue

            let clocks = cpu.execute(.convertByteToWord)

            #expect(cpu.ax == testCase.expected)
            #expect(cpu.flags.rawValue == flagsBefore)
            #expect(clocks == 2)
        }
    }

    @Test("CWD sign-extends AX into DX without changing AX")
    func convertWordToDoubleword() {
        let cases: [(input: UInt16, expectedDX: UInt16)] = [
            (0x0000, 0x0000),
            (0x7FFF, 0x0000),
            (0x8000, 0xFFFF),
            (0xFFFF, 0xFFFF),
        ]

        for testCase in cases {
            let cpu = cpuWithAX(testCase.input)
            _ = cpu.execute(.movImmediateToRegister16(.dx, 0x1234))
            setAllFlags(on: cpu)
            let flagsBefore = cpu.flags.rawValue

            let clocks = cpu.execute(.convertWordToDoubleword)

            #expect(cpu.ax == testCase.input)
            #expect(cpu.dx == testCase.expectedDX)
            #expect(cpu.flags.rawValue == flagsBefore)
            #expect(clocks == 5)
        }
    }

    @Test("XLAT uses unsigned AL, wraps BX+AL, and leaves flags untouched")
    func translateWithOffsetWrap() {
        let machine = machineWithOpcodes([0xD7])
        machine.cpu.writeSegment(0x1000, to: .ds)
        _ = machine.cpu.execute(.movImmediateToRegister16(.bx, 0xFFFF))
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, 0xAA02))
        setAllFlags(on: machine.cpu)
        _ = machine.cpu.execute(.clearFlag(.trap))
        let flagsBefore = machine.cpu.flags.rawValue
        machine.bus.writeByte(
            0xC7,
            at: AddressTranslator.physicalAddress(segment: 0x1000, offset: 0x0001)
        )

        machine.step()

        #expect(machine.cpu.ax == 0xAAC7)
        #expect(machine.cpu.flags.rawValue == flagsBefore)
        #expect(machine.cpu.ip == 1)
        #expect(machine.cycleCount == 11)
    }

    @Test("A segment override redirects XLAT away from DS")
    func translateHonorsSegmentOverride() {
        let machine = machineWithOpcodes([0x26, 0xD7]) // ES: XLAT
        machine.cpu.writeSegment(0x1000, to: .ds)
        machine.cpu.writeSegment(0x2000, to: .es)
        _ = machine.cpu.execute(.movImmediateToRegister16(.bx, 0x0100))
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, 0x5504))
        machine.bus.writeByte(
            0x11,
            at: AddressTranslator.physicalAddress(segment: 0x1000, offset: 0x0104)
        )
        machine.bus.writeByte(
            0x22,
            at: AddressTranslator.physicalAddress(segment: 0x2000, offset: 0x0104)
        )

        machine.step()

        #expect(machine.cpu.ax == 0x5522)
        #expect(machine.cpu.ip == 2)
        #expect(machine.cycleCount == 13) // prefix 2 + XLAT 11
        #expect(machine.cpu.segmentOverride == nil)
    }
}
