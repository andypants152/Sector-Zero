import Testing
@testable import Sector_Zero

/// Milestone 31 — one-iteration MOVS, LODS, and STOS semantics.
struct StringMovementTests {
    private func physical(_ segment: UInt16, _ offset: UInt16) -> UInt32 {
        AddressTranslator.physicalAddress(segment: segment, offset: offset)
    }

    private func set(_ register: Register16, to value: UInt16, on cpu: CPU8086) {
        _ = cpu.execute(.movImmediateToRegister16(register, value))
    }

    @Test("MOVS, LODS, and STOS opcodes decode without operands")
    func decodesStringMovement() {
        let decoder = InstructionDecoder()
        let cases: [(UInt8, Instruction)] = [
            (0xA4, .moveString(isWord: false)),
            (0xA5, .moveString(isWord: true)),
            (0xAA, .storeString(isWord: false)),
            (0xAB, .storeString(isWord: true)),
            (0xAC, .loadString(isWord: false)),
            (0xAD, .loadString(isWord: true)),
        ]

        for (opcode, expected) in cases {
            #expect(decoder.decode(opcode: opcode, registers: RegisterFile()) {
                Issue.record("String opcode requested an operand byte")
                return 0
            } == expected)
        }
    }

    @Test("MOVSB overrides its source while keeping its destination at ES:DI")
    func movsbSourceOverride() {
        let machine = Machine()
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x2000, to: .ss)
        cpu.writeSegment(0x3000, to: .es)
        set(.si, to: 0x0010, on: cpu)
        set(.di, to: 0x0020, on: cpu)
        machine.bus.writeByte(0x11, at: physical(0x1000, 0x0010))
        machine.bus.writeByte(0xA5, at: physical(0x2000, 0x0010))
        cpu.setSegmentOverride(.ss)
        let flags = cpu.flags

        let clocks = cpu.execute(.moveString(isWord: false))

        #expect(machine.bus.readByte(at: physical(0x3000, 0x0020)) == 0xA5)
        #expect(cpu.si == 0x0011)
        #expect(cpu.di == 0x0021)
        #expect(cpu.flags == flags)
        #expect(clocks == 18)
    }

    @Test("MOVSW moves little-endian data backward and wraps both indexes")
    func movswBackwardWrap() {
        let machine = Machine()
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x2000, to: .es)
        set(.si, to: 0, on: cpu)
        set(.di, to: 1, on: cpu)
        machine.bus.writeByte(0xCD, at: physical(0x1000, 0))
        machine.bus.writeByte(0xAB, at: physical(0x1000, 1))
        _ = cpu.execute(.setFlag(.direction))
        let flags = cpu.flags

        let clocks = cpu.execute(.moveString(isWord: true))

        #expect(machine.bus.readByte(at: physical(0x2000, 1)) == 0xCD)
        #expect(machine.bus.readByte(at: physical(0x2000, 2)) == 0xAB)
        #expect(cpu.si == 0xFFFE)
        #expect(cpu.di == 0xFFFF)
        #expect(cpu.flags == flags)
        #expect(clocks == 18)
    }

    @Test("LODSB loads AL and decrements SI when DF is set")
    func lodsbBackward() {
        let machine = Machine()
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        set(.si, to: 0, on: cpu)
        machine.bus.writeByte(0x7E, at: physical(0x1000, 0))
        _ = cpu.execute(.setFlag(.direction))
        let flags = cpu.flags

        let clocks = cpu.execute(.loadString(isWord: false))

        #expect(cpu.registers[.al] == 0x7E)
        #expect(cpu.si == 0xFFFF)
        #expect(cpu.flags == flags)
        #expect(clocks == 12)
    }

    @Test("LODSW reads across offset wrap and advances SI")
    func lodswReadWrap() {
        let machine = Machine()
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        set(.si, to: 0xFFFF, on: cpu)
        machine.bus.writeByte(0x34, at: physical(0x1000, 0xFFFF))
        machine.bus.writeByte(0x12, at: physical(0x1000, 0))
        let flags = cpu.flags

        let clocks = cpu.execute(.loadString(isWord: true))

        #expect(cpu.ax == 0x1234)
        #expect(cpu.si == 1)
        #expect(cpu.flags == flags)
        #expect(clocks == 12)
    }

    @Test("STOSB always uses ES and wraps DI forward")
    func stosbDestinationFixedToES() {
        let machine = Machine()
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x3000, to: .es)
        set(.di, to: 0xFFFF, on: cpu)
        _ = cpu.execute(.movImmediateToRegister8(.al, 0xD5))
        cpu.setSegmentOverride(.ds)
        let flags = cpu.flags

        let clocks = cpu.execute(.storeString(isWord: false))

        #expect(machine.bus.readByte(at: physical(0x3000, 0xFFFF)) == 0xD5)
        #expect(machine.bus.readByte(at: physical(0x1000, 0xFFFF)) == 0)
        #expect(cpu.di == 0)
        #expect(cpu.flags == flags)
        #expect(clocks == 11)
    }

    @Test("STOSW writes AX little-endian and decrements DI with wrap")
    func stoswBackwardWrap() {
        let machine = Machine()
        let cpu = machine.cpu
        cpu.writeSegment(0x3000, to: .es)
        set(.ax, to: 0xBEEF, on: cpu)
        set(.di, to: 0, on: cpu)
        _ = cpu.execute(.setFlag(.direction))
        let flags = cpu.flags

        let clocks = cpu.execute(.storeString(isWord: true))

        #expect(machine.bus.readByte(at: physical(0x3000, 0)) == 0xEF)
        #expect(machine.bus.readByte(at: physical(0x3000, 1)) == 0xBE)
        #expect(cpu.di == 0xFFFE)
        #expect(cpu.flags == flags)
        #expect(clocks == 11)
    }
}
