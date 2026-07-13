import Testing
@testable import Sector_Zero

/// Milestone 34 — real-mode software interrupt entry and IRET.
struct SoftwareInterruptTests {
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

    private func writeWord(_ value: UInt16, at address: UInt32, to machine: Machine) {
        machine.bus.writeByte(UInt8(truncatingIfNeeded: value), at: address)
        machine.bus.writeByte(UInt8(value >> 8), at: address + 1)
    }

    private func writeWord(_ value: UInt16, segment: UInt16, offset: UInt16, to machine: Machine) {
        machine.bus.writeByte(
            UInt8(truncatingIfNeeded: value),
            at: AddressTranslator.physicalAddress(segment: segment, offset: offset)
        )
        machine.bus.writeByte(
            UInt8(value >> 8),
            at: AddressTranslator.physicalAddress(segment: segment, offset: offset &+ 1)
        )
    }

    private func installVector(_ type: UInt8, offset: UInt16, segment: UInt16, in machine: Machine) {
        let address = UInt32(type) * 4
        writeWord(offset, at: address, to: machine)
        writeWord(segment, at: address + 2, to: machine)
    }

    @Test("CC-CF decode with an operand only for INT imm8")
    func decodesSoftwareInterrupts() {
        let decoder = InstructionDecoder()
        let forbiddenReader: () -> UInt8 = {
            Issue.record("Operand-free interrupt instruction requested a byte")
            return 0
        }

        #expect(decoder.decode(opcode: 0xCC, registers: RegisterFile(), nextByte: forbiddenReader) == .breakpointInterrupt)
        var immediate: [UInt8] = [0x80, 0xAA]
        #expect(decoder.decode(opcode: 0xCD, registers: RegisterFile()) { immediate.removeFirst() } == .softwareInterrupt(0x80))
        #expect(immediate == [0xAA])
        #expect(decoder.decode(opcode: 0xCE, registers: RegisterFile(), nextByte: forbiddenReader) == .interruptOnOverflow)
        #expect(decoder.decode(opcode: 0xCF, registers: RegisterFile(), nextByte: forbiddenReader) == .interruptReturn)
    }

    @Test("INT imm8 pushes FLAGS, CS, return IP and clears TF/IF")
    func interruptEntryFrameAndFlags() {
        // MOV SP,0100; INT 20h.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xCD, 0x20])
        machine.cpu.writeSegment(0x2000, to: .ss)
        installVector(0x20, offset: 0x5678, segment: 0x1234, in: machine)

        machine.step()
        _ = machine.cpu.execute(.setFlag(.carry))
        _ = machine.cpu.execute(.setFlag(.trap))
        _ = machine.cpu.execute(.setFlag(.interruptEnable))
        let savedFlags = machine.cpu.flags.rawValue
        machine.step()

        #expect(machine.cpu.cs == 0x1234)
        #expect(machine.cpu.ip == 0x5678)
        #expect(machine.cpu.sp == 0x00FA)
        #expect(machine.bus.readWord(at: 0x200FA) == 0x0005)
        #expect(machine.bus.readWord(at: 0x200FC) == 0xFFFF)
        #expect(machine.bus.readWord(at: 0x200FE) == savedFlags)
        #expect(!machine.cpu.flags[.trap])
        #expect(!machine.cpu.flags[.interruptEnable])
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cycleCount == 55) // MOV 4 + INT imm8 51
    }

    @Test("INT3 saves the following IP and costs 52 clocks")
    func breakpointReturnIP() {
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xCC])
        installVector(3, offset: 0x0100, segment: 0x3000, in: machine)

        machine.run(maxSteps: 2)

        #expect(machine.cpu.cs == 0x3000)
        #expect(machine.cpu.ip == 0x0100)
        #expect(machine.cpu.sp == 0x00FA)
        #expect(machine.bus.readWord(at: 0x00FA) == 0x0004)
        #expect(machine.cycleCount == 56) // MOV 4 + INT3 52
    }

    @Test("INTO enters vector 4 only while OF is set")
    func interruptOnOverflowPaths() {
        let notTaken = machineWithOpcodes([0xCE])
        notTaken.step()
        #expect(notTaken.cpu.cs == 0xFFFF)
        #expect(notTaken.cpu.ip == 1)
        #expect(notTaken.cpu.sp == 0)
        #expect(notTaken.cycleCount == 4)

        let taken = machineWithOpcodes([0xBC, 0x00, 0x01, 0xCE])
        installVector(4, offset: 0x2222, segment: 0x3333, in: taken)
        taken.step()
        _ = taken.cpu.execute(.setFlag(.overflow))
        taken.step()
        #expect(taken.cpu.cs == 0x3333)
        #expect(taken.cpu.ip == 0x2222)
        #expect(taken.cpu.sp == 0x00FA)
        #expect(taken.bus.readWord(at: 0x00FA) == 0x0004)
        #expect(taken.cpu.flags[.overflow])
        #expect(taken.cycleCount == 57) // MOV 4 + taken INTO 53
    }

    @Test("Nested INT and IRET restore CS:IP, FLAGS, and SP")
    func nestedInterruptRoundTrip() {
        // MOV SP,0200; STI; INT 20h; HLT.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x02, 0xFB, 0xCD, 0x20, 0xF4])
        installVector(0x20, offset: 0, segment: 0x1000, in: machine)
        installVector(0x21, offset: 0, segment: 0x2000, in: machine)
        machine.bus.writeByte(0xCD, at: 0x10000) // INT 21h
        machine.bus.writeByte(0x21, at: 0x10001)
        machine.bus.writeByte(0xCF, at: 0x10002) // IRET
        machine.bus.writeByte(0xCF, at: 0x20000) // nested IRET

        machine.run(maxSteps: 7)

        #expect(machine.cpu.halted)
        #expect(machine.cpu.cs == 0xFFFF)
        #expect(machine.cpu.ip == 0x0007)
        #expect(machine.cpu.sp == 0x0200)
        #expect(machine.cpu.flags.rawValue == 0xF202)
        #expect(machine.cycleCount == 158)
    }

    @Test("INT FF reads the highest little-endian IVT entry while SP wraps")
    func highestVectorAndStackWrap() {
        let machine = machineWithOpcodes([0xCD, 0xFF])
        installVector(0xFF, offset: 0xBEEF, segment: 0xCAFE, in: machine)

        machine.step()

        #expect(machine.cpu.cs == 0xCAFE)
        #expect(machine.cpu.ip == 0xBEEF)
        #expect(machine.cpu.sp == 0xFFFA)
        #expect(machine.bus.readWord(at: 0xFFFA) == 0x0002)
        #expect(machine.bus.readWord(at: 0xFFFC) == 0xFFFF)
        #expect(machine.bus.readWord(at: 0xFFFE) == 0xF002)
        #expect(machine.cycleCount == 51)
    }

    @Test("IRET pops IP, CS, FLAGS and normalizes reserved flag bits")
    func interruptReturnNormalizesFlags() {
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xCF])
        writeWord(0x3456, segment: 0, offset: 0x0100, to: machine)
        writeWord(0x789A, segment: 0, offset: 0x0102, to: machine)
        writeWord(0xFFFF, segment: 0, offset: 0x0104, to: machine)

        machine.run(maxSteps: 2)

        #expect(machine.cpu.ip == 0x3456)
        #expect(machine.cpu.cs == 0x789A)
        #expect(machine.cpu.sp == 0x0106)
        #expect(machine.cpu.flags.rawValue == 0xFFD7)
        #expect(machine.cycleCount == 28) // MOV 4 + IRET 24
    }
}
