import Testing
@testable import Sector_Zero

/// Milestone 29 — inter-segment CALL/JMP and RET variants.
struct FarTransferTests {
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

    @Test("Far transfer and adjusted return opcodes decode")
    func decodesFarTransfersAndReturns() {
        let decoder = InstructionDecoder()

        var direct: [UInt8] = [0x34, 0x12, 0x78, 0x56]
        #expect(decoder.decode(opcode: 0x9A, registers: RegisterFile()) { direct.removeFirst() }
            == .callFar(offset: 0x1234, segment: 0x5678))

        var callBytes: [UInt8] = [0x1E, 0x40, 0x00]
        #expect(decoder.decode(opcode: 0xFF, registers: RegisterFile()) { callBytes.removeFirst() }
            == .callFarIndirect(
                source: .memory(EffectiveAddress(offset: 0x0040, defaultSegment: .ds)),
                eaClocks: 6
            ))

        var jumpBytes: [UInt8] = [0x2E, 0x40, 0x00]
        #expect(decoder.decode(opcode: 0xFF, registers: RegisterFile()) { jumpBytes.removeFirst() }
            == .jumpFarIndirect(
                source: .memory(EffectiveAddress(offset: 0x0040, defaultSegment: .ds)),
                eaClocks: 6
            ))

        var nearAdjustment: [UInt8] = [0x34, 0x12]
        #expect(decoder.decode(opcode: 0xC2, registers: RegisterFile()) { nearAdjustment.removeFirst() }
            == .returnNearAdjust(0x1234))
        #expect(decoder.decode(opcode: 0xCB, registers: RegisterFile()) {
            Issue.record("RETF requested an operand byte")
            return 0
        } == .returnFar)
        var farAdjustment: [UInt8] = [0x78, 0x56]
        #expect(decoder.decode(opcode: 0xCA, registers: RegisterFile()) { farAdjustment.removeFirst() }
            == .returnFarAdjust(0x5678))
    }

    @Test("FF far selectors reject register operands after consuming ModR/M")
    func rejectsRegisterFarPointers() {
        let decoder = InstructionDecoder()
        var callBytes: [UInt8] = [0xD8, 0xAA]
        #expect(decoder.decode(opcode: 0xFF, registers: RegisterFile()) { callBytes.removeFirst() } == .unknown(0xFF))
        #expect(callBytes == [0xAA])

        var jumpBytes: [UInt8] = [0xE8, 0xBB]
        #expect(decoder.decode(opcode: 0xFF, registers: RegisterFile()) { jumpBytes.removeFirst() } == .unknown(0xFF))
        #expect(jumpBytes == [0xBB])
    }

    @Test("Direct far CALL pushes CS then return IP and RETF round-trips")
    func directFarCallRoundTripAndStackOrder() {
        // MOV SP,0100; CALL 1000:0000; HLT. The target contains RETF.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0x9A, 0x00, 0x00, 0x00, 0x10,
            0xF4,
        ])
        machine.bus.writeByte(0xCB, at: 0x10000)
        let flags = machine.cpu.flags

        machine.step() // MOV SP
        machine.step() // CALL far
        #expect(machine.cpu.cs == 0x1000)
        #expect(machine.cpu.ip == 0)
        #expect(machine.cpu.sp == 0x00FC)
        #expect(machine.bus.readByte(at: 0x00FC) == 0x08) // return IP
        #expect(machine.bus.readByte(at: 0x00FD) == 0x00)
        #expect(machine.bus.readByte(at: 0x00FE) == 0xFF) // return CS
        #expect(machine.bus.readByte(at: 0x00FF) == 0xFF)

        machine.run(maxSteps: 2)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.cs == 0xFFFF)
        #expect(machine.cpu.sp == 0x0100)
        #expect(machine.cpu.flags == flags)
        #expect(machine.cycleCount == 60) // MOV 4 + CALL 28 + RETF 26 + HLT 2
    }

    @Test("Indirect far CALL reads m16:16 and RETF round-trips")
    func indirectFarCallRoundTrip() {
        // MOV SP,0100; CALL far [0040]; HLT.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0xFF, 0x1E, 0x40, 0x00,
            0xF4,
        ])
        writeWord(0x0000, segment: 0, offset: 0x0040, to: machine)
        writeWord(0x1000, segment: 0, offset: 0x0042, to: machine)
        machine.bus.writeByte(0xCB, at: 0x10000)
        let flags = machine.cpu.flags

        machine.run(maxSteps: 4)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.cs == 0xFFFF)
        #expect(machine.cpu.sp == 0x0100)
        #expect(machine.cpu.flags == flags)
        #expect(machine.cycleCount == 75) // MOV 4 + CALL 37+EA 6 + RETF 26 + HLT 2
    }

    @Test("Far JMP pointer honors an override and wraps between pointer words")
    func farJumpOverrideAndPointerWrap() {
        // MOV BX,FFFE; ES: JMP far [BX]. The segment word begins at ES:0000.
        let machine = machineWithOpcodes([
            0xBB, 0xFE, 0xFF,
            0x26, 0xFF, 0x2F,
        ])
        machine.cpu.writeSegment(0x2000, to: .es)
        writeWord(0x0100, segment: 0x2000, offset: 0xFFFE, to: machine)
        writeWord(0x3000, segment: 0x2000, offset: 0x0000, to: machine)
        // A conflicting DS pointer catches a lost override.
        writeWord(0x0200, segment: 0, offset: 0xFFFE, to: machine)
        writeWord(0x4000, segment: 0, offset: 0, to: machine)
        machine.bus.writeByte(0xF4, at: AddressTranslator.physicalAddress(segment: 0x3000, offset: 0x0100))
        let flags = machine.cpu.flags

        machine.run(maxSteps: 3)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.cs == 0x3000)
        #expect(machine.cpu.ip == 0x0101)
        #expect(machine.cpu.sp == 0)
        #expect(machine.cpu.flags == flags)
        #expect(machine.cycleCount == 37) // MOV 4 + prefix 2 + JMP 24+EA 5 + HLT 2
    }

    @Test("RET near imm16 pops IP before caller cleanup")
    func nearReturnWithCleanup() {
        // MOV SP,0100; RET 4. The stack return address points at the HLT.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xC2, 0x04, 0x00, 0xF4])
        writeWord(0x0006, segment: 0, offset: 0x0100, to: machine)
        let flags = machine.cpu.flags

        machine.run(maxSteps: 3)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.sp == 0x0106)
        #expect(machine.cpu.flags == flags)
        #expect(machine.cycleCount == 26) // MOV 4 + RET imm 20 + HLT 2
    }

    @Test("RET far imm16 restores IP and CS before caller cleanup")
    func farReturnWithCleanup() {
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xCA, 0x04, 0x00])
        writeWord(0x0000, segment: 0, offset: 0x0100, to: machine)
        writeWord(0x2000, segment: 0, offset: 0x0102, to: machine)
        machine.bus.writeByte(0xF4, at: 0x20000)
        let flags = machine.cpu.flags

        machine.run(maxSteps: 3)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.cs == 0x2000)
        #expect(machine.cpu.ip == 1)
        #expect(machine.cpu.sp == 0x0108)
        #expect(machine.cpu.flags == flags)
        #expect(machine.cycleCount == 31) // MOV 4 + RETF imm 25 + HLT 2
    }
}
