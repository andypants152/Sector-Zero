import Testing
@testable import Sector_Zero

/// Milestone 32 — one-iteration CMPS and SCAS semantics.
struct StringComparisonTests {
    private func physical(_ segment: UInt16, _ offset: UInt16) -> UInt32 {
        AddressTranslator.physicalAddress(segment: segment, offset: offset)
    }

    private func set(_ register: Register16, to value: UInt16, on cpu: CPU8086) {
        _ = cpu.execute(.movImmediateToRegister16(register, value))
    }

    private func writeWord(_ value: UInt16, segment: UInt16, offset: UInt16, to machine: Machine) {
        machine.bus.writeByte(UInt8(truncatingIfNeeded: value), at: physical(segment, offset))
        machine.bus.writeByte(UInt8(value >> 8), at: physical(segment, offset &+ 1))
    }

    @Test("CMPS and SCAS byte/word opcodes decode without operands")
    func decodesStringComparisons() {
        let decoder = InstructionDecoder()
        let cases: [(UInt8, Instruction)] = [
            (0xA6, .compareString(isWord: false)),
            (0xA7, .compareString(isWord: true)),
            (0xAE, .scanString(isWord: false)),
            (0xAF, .scanString(isWord: true)),
        ]

        for (opcode, expected) in cases {
            #expect(decoder.decode(opcode: opcode, registers: RegisterFile()) {
                Issue.record("String comparison requested an operand byte")
                return 0
            } == expected)
        }
    }

    @Test("CMPSB compares overrideable source minus fixed ES destination")
    func cmpsbEqualityWithSourceOverride() {
        let machine = Machine()
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x2000, to: .ss)
        cpu.writeSegment(0x3000, to: .es)
        set(.si, to: 0x0010, on: cpu)
        set(.di, to: 0x0020, on: cpu)
        machine.bus.writeByte(0x11, at: physical(0x1000, 0x0010))
        machine.bus.writeByte(0x44, at: physical(0x2000, 0x0010))
        machine.bus.writeByte(0x44, at: physical(0x3000, 0x0020))
        cpu.setSegmentOverride(.ss)

        let clocks = cpu.execute(.compareString(isWord: false))

        #expect(cpu.flags[.zero])
        #expect(!cpu.flags[.carry])
        #expect(cpu.si == 0x0011)
        #expect(cpu.di == 0x0021)
        #expect(machine.bus.readByte(at: physical(0x2000, 0x0010)) == 0x44)
        #expect(machine.bus.readByte(at: physical(0x3000, 0x0020)) == 0x44)
        #expect(clocks == 22)
    }

    @Test("CMPSW operand order produces borrow and DF wraps both indexes")
    func cmpswBorrowBackward() {
        let machine = Machine()
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x2000, to: .es)
        set(.si, to: 0, on: cpu)
        set(.di, to: 0, on: cpu)
        writeWord(0x0001, segment: 0x1000, offset: 0, to: machine)
        writeWord(0x0002, segment: 0x2000, offset: 0, to: machine)
        _ = cpu.execute(.setFlag(.direction))

        let clocks = cpu.execute(.compareString(isWord: true))

        #expect(cpu.flags[.carry]) // source 1 minus destination 2
        #expect(cpu.flags[.sign])
        #expect(!cpu.flags[.zero])
        #expect(cpu.flags[.direction])
        #expect(cpu.si == 0xFFFE)
        #expect(cpu.di == 0xFFFE)
        #expect(clocks == 22)
    }

    @Test("SCASB uses AL minus ES:DI, ignores overrides, and sets overflow")
    func scasbOverflowAndFixedSegment() {
        let machine = Machine()
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x3000, to: .es)
        set(.di, to: 0, on: cpu)
        _ = cpu.execute(.movImmediateToRegister8(.al, 0x80))
        machine.bus.writeByte(0x80, at: physical(0x1000, 0)) // wrong override target
        machine.bus.writeByte(0x01, at: physical(0x3000, 0))
        cpu.setSegmentOverride(.ds)
        _ = cpu.execute(.setFlag(.direction))

        let clocks = cpu.execute(.scanString(isWord: false))

        #expect(cpu.flags[.overflow]) // 0x80 - 0x01 = 0x7F
        #expect(!cpu.flags[.carry])
        #expect(!cpu.flags[.sign])
        #expect(!cpu.flags[.zero])
        #expect(cpu.flags[.direction])
        #expect(cpu.di == 0xFFFF)
        #expect(machine.bus.readByte(at: physical(0x3000, 0)) == 0x01)
        #expect(clocks == 15)
    }

    @Test("SCASW reads across offset wrap and advances DI")
    func scaswEqualityAtWrap() {
        let machine = Machine()
        let cpu = machine.cpu
        cpu.writeSegment(0x3000, to: .es)
        set(.ax, to: 0x1234, on: cpu)
        set(.di, to: 0xFFFF, on: cpu)
        writeWord(0x1234, segment: 0x3000, offset: 0xFFFF, to: machine)

        let clocks = cpu.execute(.scanString(isWord: true))

        #expect(cpu.flags[.zero])
        #expect(!cpu.flags[.carry])
        #expect(cpu.di == 1)
        #expect(cpu.ax == 0x1234)
        #expect(clocks == 15)
    }
}
