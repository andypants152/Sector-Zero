import Testing
@testable import Sector_Zero

/// Milestone 33 — REP/REPE/REPNE prefix composition and counted strings.
struct RepeatPrefixTests {
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

    @Test("REP MOVSB runs many iterations atomically and wraps indexes")
    func repMovsbMany() {
        let machine = machineWithOpcodes([0xF3, 0xA4])
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x2000, to: .es)
        set(.cx, to: 3, on: cpu)
        set(.si, to: 0xFFFE, on: cpu)
        set(.di, to: 0xFFFE, on: cpu)
        machine.bus.writeByte(0x11, at: physical(0x1000, 0xFFFE))
        machine.bus.writeByte(0x22, at: physical(0x1000, 0xFFFF))
        machine.bus.writeByte(0x33, at: physical(0x1000, 0))

        machine.step()

        #expect(cpu.cx == 0)
        #expect(cpu.si == 1)
        #expect(cpu.di == 1)
        #expect(cpu.ip == 2)
        #expect(machine.bus.readByte(at: physical(0x2000, 0xFFFE)) == 0x11)
        #expect(machine.bus.readByte(at: physical(0x2000, 0xFFFF)) == 0x22)
        #expect(machine.bus.readByte(at: physical(0x2000, 0)) == 0x33)
        #expect(machine.cycleCount == 60) // 9 + 17×3
    }

    @Test("REP with CX zero performs setup but no data access")
    func zeroCountDoesNotAccessData() {
        let machine = machineWithOpcodes([0xF3, 0xA4])
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x2000, to: .es)
        set(.si, to: 0x0010, on: cpu)
        set(.di, to: 0x0020, on: cpu)
        machine.bus.writeByte(0x55, at: physical(0x1000, 0x0010))
        machine.bus.writeByte(0xAA, at: physical(0x2000, 0x0020))

        machine.step()

        #expect(cpu.cx == 0)
        #expect(cpu.si == 0x0010)
        #expect(cpu.di == 0x0020)
        #expect(machine.bus.readByte(at: physical(0x2000, 0x0020)) == 0xAA)
        #expect(machine.cycleCount == 9)
    }

    @Test("REPE CMPS stops after the first unequal element")
    func repeCmpsEarlyExit() {
        let machine = machineWithOpcodes([0xF3, 0xA6])
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x2000, to: .es)
        set(.cx, to: 3, on: cpu)
        for (offset, value) in [UInt8(1), 2, 3].enumerated() {
            machine.bus.writeByte(value, at: physical(0x1000, UInt16(offset)))
        }
        for (offset, value) in [UInt8(1), 9, 3].enumerated() {
            machine.bus.writeByte(value, at: physical(0x2000, UInt16(offset)))
        }

        machine.step()

        #expect(cpu.cx == 1)
        #expect(cpu.si == 2)
        #expect(cpu.di == 2)
        #expect(!cpu.flags[.zero])
        #expect(machine.cycleCount == 53) // 9 + 22×2
    }

    @Test("REPNE SCAS stops after the first equal element")
    func repneScasEarlyExit() {
        let machine = machineWithOpcodes([0xF2, 0xAE])
        let cpu = machine.cpu
        cpu.writeSegment(0x2000, to: .es)
        set(.cx, to: 3, on: cpu)
        _ = cpu.execute(.movImmediateToRegister8(.al, 7))
        machine.bus.writeByte(1, at: physical(0x2000, 0))
        machine.bus.writeByte(7, at: physical(0x2000, 1))
        machine.bus.writeByte(7, at: physical(0x2000, 2))

        machine.step()

        #expect(cpu.cx == 1)
        #expect(cpu.di == 2)
        #expect(cpu.flags[.zero])
        #expect(machine.cycleCount == 39) // 9 + 15×2
    }

    @Test("Segment and repeat prefixes compose with DF on REP MOVSW")
    func mixedPrefixesAndDirection() {
        // REP SS: MOVSW — prefix order is deliberately repeat then segment.
        let machine = machineWithOpcodes([0xF3, 0x36, 0xA5])
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x2000, to: .ss)
        cpu.writeSegment(0x3000, to: .es)
        set(.cx, to: 2, on: cpu)
        set(.si, to: 2, on: cpu)
        set(.di, to: 2, on: cpu)
        _ = cpu.execute(.setFlag(.direction))
        writeWord(0x1111, segment: 0x1000, offset: 2, to: machine) // wrong DS source
        writeWord(0xABCD, segment: 0x2000, offset: 2, to: machine)
        writeWord(0x1234, segment: 0x2000, offset: 0, to: machine)

        machine.step()

        #expect(cpu.cx == 0)
        #expect(cpu.si == 0xFFFE)
        #expect(cpu.di == 0xFFFE)
        #expect(machine.bus.readByte(at: physical(0x3000, 2)) == 0xCD)
        #expect(machine.bus.readByte(at: physical(0x3000, 3)) == 0xAB)
        #expect(machine.bus.readByte(at: physical(0x3000, 0)) == 0x34)
        #expect(machine.bus.readByte(at: physical(0x3000, 1)) == 0x12)
        #expect(machine.cycleCount == 45) // segment 2 + repeat 9 + 17×2
    }

    @Test("Last repeat prefix wins and redundant prefixes cost two clocks")
    func lastRepeatPrefixWins() {
        // Last prefix is REPE. First pair equal => continue; second differs.
        let machine = machineWithOpcodes([0xF2, 0xF3, 0xA6])
        let cpu = machine.cpu
        cpu.writeSegment(0x1000, to: .ds)
        cpu.writeSegment(0x2000, to: .es)
        set(.cx, to: 2, on: cpu)
        machine.bus.writeByte(1, at: physical(0x1000, 0))
        machine.bus.writeByte(2, at: physical(0x1000, 1))
        machine.bus.writeByte(1, at: physical(0x2000, 0))
        machine.bus.writeByte(9, at: physical(0x2000, 1))

        machine.step()

        #expect(cpu.cx == 0)
        #expect(!cpu.flags[.zero])
        #expect(machine.cycleCount == 55) // two prefixes 4 + setup 7 + 22×2
    }

    @Test("REP LODS and STOS use their repeat timing formulas")
    func repeatLoadAndStoreTiming() {
        let load = machineWithOpcodes([0xF3, 0xAC])
        load.cpu.writeSegment(0x1000, to: .ds)
        set(.cx, to: 1, on: load.cpu)
        load.bus.writeByte(0x7A, at: physical(0x1000, 0))
        load.step()
        #expect(load.cpu.registers[.al] == 0x7A)
        #expect(load.cpu.cx == 0)
        #expect(load.cpu.si == 1)
        #expect(load.cycleCount == 22) // 9 + 13×1

        let store = machineWithOpcodes([0xF3, 0xAA])
        store.cpu.writeSegment(0x2000, to: .es)
        set(.cx, to: 2, on: store.cpu)
        _ = store.cpu.execute(.movImmediateToRegister8(.al, 0x5C))
        store.step()
        #expect(store.cpu.cx == 0)
        #expect(store.cpu.di == 2)
        #expect(store.bus.readByte(at: physical(0x2000, 0)) == 0x5C)
        #expect(store.bus.readByte(at: physical(0x2000, 1)) == 0x5C)
        #expect(store.cycleCount == 29) // 9 + 10×2
    }

    @Test("Repeat prefix on an unrelated opcode is consumed without repetition")
    func unrelatedOpcodeExecutesOnce() {
        let machine = machineWithOpcodes([0xF3, 0x90])
        set(.cx, to: 4, on: machine.cpu)

        machine.step()

        #expect(machine.cpu.cx == 4)
        #expect(machine.cpu.ip == 2)
        #expect(machine.cycleCount == 5) // prefix 2 + NOP 3
    }
}
