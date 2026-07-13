import Testing
@testable import Sector_Zero

/// Milestone 28 — FF /2 CALL and /4 JMP near absolute indirect forms.
/// Targets are resolved before CALL mutates SP and neither form changes CS or
/// FLAGS.
struct IndirectNearTransferTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            let address = (resetVector + UInt32(offset)) & AddressTranslator.physicalAddressMask
            machine.bus.writeByte(opcode, at: address)
        }
        return machine
    }

    @Test("FF /2 and /4 decode register and memory sources")
    func decodesIndirectNearTransfers() {
        let decoder = InstructionDecoder()
        #expect(decoder.decode(opcode: 0xFF, registers: RegisterFile()) { 0xD3 }
            == .callNearIndirect(source: .register(3), eaClocks: 0))
        #expect(decoder.decode(opcode: 0xFF, registers: RegisterFile()) { 0xE3 }
            == .jumpNearIndirect(source: .register(3), eaClocks: 0))

        var callBytes: [UInt8] = [0x16, 0x40, 0x00]
        #expect(decoder.decode(opcode: 0xFF, registers: RegisterFile()) { callBytes.removeFirst() }
            == .callNearIndirect(
                source: .memory(EffectiveAddress(offset: 0x0040, defaultSegment: .ds)),
                eaClocks: 6
            ))
    }

    @Test("Register-indirect CALL pushes post-decode IP and returns")
    func registerCallRoundTrip() {
        // MOV SP,0100; MOV BX,0009; CALL BX; HLT; RET.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0xBB, 0x09, 0x00,
            0xFF, 0xD3,
            0xF4,
            0xC3,
        ])
        let flags = machine.cpu.flags
        machine.run(maxSteps: 10)

        #expect(machine.cpu.halted)
        #expect(machine.cpu.sp == 0x0100)
        #expect(machine.bus.readByte(at: 0x00FE) == 0x08)
        #expect(machine.bus.readByte(at: 0x00FF) == 0x00)
        #expect(machine.cpu.flags == flags)
        #expect(machine.cycleCount == 42) // MOVs 8 + CALL 16 + RET 16 + HLT 2
    }

    @Test("Memory-indirect CALL uses an absolute target and 21+EA clocks")
    func memoryCallRoundTrip() {
        // MOV SP,0100; CALL word [0040]; HLT; RET.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0xFF, 0x16, 0x40, 0x00,
            0xF4,
            0xC3,
        ])
        machine.bus.writeByte(0x08, at: 0x0040)
        machine.bus.writeByte(0x00, at: 0x0041)
        machine.run(maxSteps: 10)

        #expect(machine.cpu.halted)
        #expect(machine.cpu.sp == 0x0100)
        #expect(machine.bus.readByte(at: 0x00FE) == 0x07)
        #expect(machine.cycleCount == 49) // MOV 4 + CALL 27 + RET 16 + HLT 2
    }

    @Test("Memory CALL reads a target before its stack push overwrites that word")
    func memoryCallOrdering() {
        // SP=0042 and BP=0040. CALL [BP] must read target 000A before pushing
        // return IP 0009 onto the same SS:0040 word.
        let machine = machineWithOpcodes([
            0xBC, 0x42, 0x00,
            0xBD, 0x40, 0x00,
            0xFF, 0x56, 0x00,
            0xF4,
            0xC3,
        ])
        machine.bus.writeByte(0x0A, at: 0x0040)
        machine.bus.writeByte(0x00, at: 0x0041)
        machine.run(maxSteps: 10)

        #expect(machine.cpu.halted)
        #expect(machine.cpu.sp == 0x0042)
        #expect(machine.bus.readByte(at: 0x0040) == 0x09)
        #expect(machine.cycleCount == 56) // MOVs 8 + CALL 21+EA 9 + RET 16 + HLT 2
    }

    @Test("Register-indirect JMP loads an absolute IP and leaves CS alone")
    func registerJump() {
        // MOV BX,0008; JMP BX; padding; HLT.
        let machine = machineWithOpcodes([
            0xBB, 0x08, 0x00,
            0xFF, 0xE3,
            0x90, 0x90, 0x90,
            0xF4,
        ])
        let flags = machine.cpu.flags
        machine.run(maxSteps: 3)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.ip == 0x0009)
        #expect(machine.cpu.cs == 0xFFFF)
        #expect(machine.cpu.flags == flags)
        #expect(machine.cycleCount == 17) // MOV 4 + JMP 11 + HLT 2
    }

    @Test("Segment override redirects a memory JMP pointer")
    func memoryJumpHonorsOverride() {
        // ES: JMP word [0040]; padding; HLT at absolute offset 8.
        let machine = machineWithOpcodes([
            0x26, 0xFF, 0x26, 0x40, 0x00,
            0x90, 0x90, 0x90,
            0xF4,
        ])
        machine.cpu.writeSegment(0x2000, to: .es)
        machine.bus.writeByte(0x08, at: 0x20040)
        machine.bus.writeByte(0x00, at: 0x20041)
        machine.bus.writeByte(0x05, at: 0x00040) // wrong DS target
        machine.bus.writeByte(0x00, at: 0x00041)
        machine.run(maxSteps: 2)

        #expect(machine.cpu.halted)
        #expect(machine.cpu.ip == 0x0009)
        #expect(machine.cycleCount == 28) // prefix 2 + JMP 18+EA 6 + HLT 2
    }

    @Test("CALL SP resolves the old SP before pushing the return address")
    func callSPOrdering() {
        // MOV SP,0010; CALL SP; padding; HLT at offset 0010.
        var opcodes: [UInt8] = [0xBC, 0x10, 0x00, 0xFF, 0xD4]
        opcodes += [UInt8](repeating: 0x90, count: 11)
        opcodes.append(0xF4)
        let machine = machineWithOpcodes(opcodes)
        machine.run(maxSteps: 3)

        #expect(machine.cpu.halted)
        #expect(machine.cpu.sp == 0x000E)
        #expect(machine.bus.readByte(at: 0x000E) == 0x05)
        #expect(machine.bus.readByte(at: 0x000F) == 0x00)
        #expect(machine.cycleCount == 22)
    }

    @Test("Indirect CALL stack push wraps from SP zero")
    func callStackWrap() {
        // MOV BX,0006; CALL BX with reset SP=0.
        let machine = machineWithOpcodes([0xBB, 0x06, 0x00, 0xFF, 0xD3, 0x90, 0xF4])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ip == 0x0006)
        #expect(machine.cpu.sp == 0xFFFE)
        #expect(machine.bus.readByte(at: 0xFFFE) == 0x05)
        #expect(machine.bus.readByte(at: 0xFFFF) == 0x00)
        #expect(machine.cycleCount == 20)
    }

    @Test("Indirect JMP target at FFFF wraps IP after the next fetch")
    func jumpTargetWrap() {
        let machine = machineWithOpcodes([0xB8, 0xFF, 0xFF, 0xFF, 0xE0])
        let target = AddressTranslator.physicalAddress(segment: 0xFFFF, offset: 0xFFFF)
        machine.bus.writeByte(0xF4, at: target)
        machine.run(maxSteps: 3)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.ip == 0)
        #expect(machine.cpu.cs == 0xFFFF)
    }
}
