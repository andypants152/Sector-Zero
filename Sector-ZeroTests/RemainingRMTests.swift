import Testing
@testable import Sector_Zero

/// Milestone 27 — FE/FF INC/DEC r/m, FF /6 PUSH r/m16, and 8F /0
/// POP r/m16. Data operands honor segment overrides; stack traffic stays on SS.
struct RemainingRMTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    @Test("FE/FF and 8F decode every M27 selector")
    func decodesM27Selectors() {
        let decoder = InstructionDecoder()
        #expect(decoder.decode(opcode: 0xFE, registers: RegisterFile()) { 0xC0 }
            == .incRM8(destination: .register(0), eaClocks: 0))
        #expect(decoder.decode(opcode: 0xFE, registers: RegisterFile()) { 0xC8 }
            == .decRM8(destination: .register(0), eaClocks: 0))
        #expect(decoder.decode(opcode: 0xFF, registers: RegisterFile()) { 0xC0 }
            == .incRM16(destination: .register(0), eaClocks: 0))
        #expect(decoder.decode(opcode: 0xFF, registers: RegisterFile()) { 0xC8 }
            == .decRM16(destination: .register(0), eaClocks: 0))
        #expect(decoder.decode(opcode: 0xFF, registers: RegisterFile()) { 0xF0 }
            == .pushRM16(source: .register(0), eaClocks: 0))
        #expect(decoder.decode(opcode: 0x8F, registers: RegisterFile()) { 0xC0 }
            == .popRM16(destination: .register(0), eaClocks: 0))
    }

    @Test("FE register INC/DEC updates byte flags and preserves CF")
    func byteRegisterForms() {
        // STC; MOV AL,7F; INC AL; DEC AL.
        let machine = machineWithOpcodes([0xF9, 0xB0, 0x7F, 0xFE, 0xC0, 0xFE, 0xC8])
        machine.run(maxSteps: 4)
        #expect(machine.cpu.registers[.al] == 0x7F)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cpu.flags[.overflow]) // DEC 80h -> 7Fh
        #expect(machine.cycleCount == 12) // STC 2 + MOV 4 + INC/DEC 3 each
    }

    @Test("FF register INC/DEC updates word flags and preserves clear CF")
    func wordRegisterForms() {
        // MOV AX,7FFF; INC AX; DEC AX.
        let machine = machineWithOpcodes([0xB8, 0xFF, 0x7F, 0xFF, 0xC0, 0xFF, 0xC8])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.registers[.ax] == 0x7FFF)
        #expect(!machine.cpu.flags[.carry])
        #expect(machine.cpu.flags[.overflow]) // DEC 8000h -> 7FFFh
        #expect(machine.cycleCount == 10)
    }

    @Test("Memory INC/DEC works at both widths with 15+EA timing")
    func memoryIncDecBothWidths() {
        // INC byte [0040]; DEC word [0050]. Direct-address EA is 6 clocks.
        let machine = machineWithOpcodes([
            0xFE, 0x06, 0x40, 0x00,
            0xFF, 0x0E, 0x50, 0x00,
        ])
        machine.bus.writeByte(0x0F, at: 0x0040)
        machine.bus.writeByte(0x00, at: 0x0050)
        machine.bus.writeByte(0x80, at: 0x0051)
        machine.run(maxSteps: 2)
        #expect(machine.bus.readByte(at: 0x0040) == 0x10)
        #expect(machine.bus.readByte(at: 0x0050) == 0xFF)
        #expect(machine.bus.readByte(at: 0x0051) == 0x7F)
        #expect(machine.cpu.flags[.overflow])
        #expect(machine.cycleCount == 42)
    }

    @Test("BP-based data defaults to SS and an override redirects it")
    func bpDefaultAndOverride() {
        // MOV BP,0040; INC byte [BP]; DS: INC byte [BP].
        let machine = machineWithOpcodes([
            0xBD, 0x40, 0x00,
            0xFE, 0x46, 0x00,
            0x3E, 0xFE, 0x46, 0x00,
        ])
        machine.cpu.writeSegment(0x2000, to: .ss)
        machine.cpu.writeSegment(0x1000, to: .ds)
        machine.bus.writeByte(0x10, at: 0x20040)
        machine.bus.writeByte(0x20, at: 0x10040)
        machine.run(maxSteps: 3)
        #expect(machine.bus.readByte(at: 0x20040) == 0x11)
        #expect(machine.bus.readByte(at: 0x10040) == 0x21)
        #expect(machine.cycleCount == 54)
    }

    @Test("PUSH/POP memory keep stack on SS while data follows ES override")
    func memoryPushPopSegmentsAndTiming() {
        // MOV SP,0100; ES: PUSH word [0040]; ES: POP word [0050].
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0x26, 0xFF, 0x36, 0x40, 0x00,
            0x26, 0x8F, 0x06, 0x50, 0x00,
        ])
        machine.cpu.writeSegment(0x2000, to: .es)
        machine.cpu.writeSegment(0x3000, to: .ss)
        machine.bus.writeByte(0xEF, at: 0x20040)
        machine.bus.writeByte(0xBE, at: 0x20041)
        machine.run(maxSteps: 3)

        #expect(machine.cpu.sp == 0x0100)
        #expect(machine.bus.readByte(at: 0x300FE) == 0xEF)
        #expect(machine.bus.readByte(at: 0x300FF) == 0xBE)
        #expect(machine.bus.readByte(at: 0x20050) == 0xEF)
        #expect(machine.bus.readByte(at: 0x20051) == 0xBE)
        #expect(machine.cycleCount == 53) // MOV 4 + prefixes 4 + PUSH 22 + POP 23
    }

    @Test("FF /6 PUSH SP stores the post-decrement value")
    func pushSPQuirk() {
        // MOV SP,0100; PUSH SP via FF /6; POP AX via 8F /0.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xFF, 0xF4, 0x8F, 0xC0])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.registers[.ax] == 0x00FE)
        #expect(machine.cpu.sp == 0x0100)
        #expect(machine.cycleCount == 23)
    }

    @Test("8F /0 POP SP loads the popped value after stack increment")
    func popIntoSP() {
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0x8F, 0xC4])
        machine.cpu.writeSegment(0x2000, to: .ss)
        machine.bus.writeByte(0x55, at: 0x20100)
        machine.bus.writeByte(0x05, at: 0x20101)
        machine.run(maxSteps: 2)
        #expect(machine.cpu.sp == 0x0555)
        #expect(machine.cycleCount == 12)
    }

    @Test("FF /6 and 8F /0 wrap SP across the segment boundary")
    func stackPointerWrap() {
        // PUSH AX from reset SP=0, then POP BX.
        let machine = machineWithOpcodes([0xB8, 0x34, 0x12, 0xFF, 0xF0, 0x8F, 0xC3])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.registers[.bx] == 0x1234)
        #expect(machine.cpu.sp == 0)
    }

    @Test("Unsupported group selectors consume addressing bytes before faulting", arguments: [
        (UInt8(0x8F), UInt8(0x0E)), // /1
        (UInt8(0xFE), UInt8(0x16)), // /2
        (UInt8(0xFF), UInt8(0x3E)), // /7
    ])
    func unsupportedSelectorsStayAligned(opcode: UInt8, modRM: UInt8) {
        let machine = machineWithOpcodes([opcode, modRM, 0x40, 0x00, 0xF4])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ip == 4)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.fault == .unsupportedOpcode(opcode))
    }
}
