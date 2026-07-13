import Testing
@testable import Sector_Zero

/// Milestone 19 — Logical ALU AND/OR/XOR (0x08–0x0B, 0x20–0x23, 0x30–0x33)
/// plus their immediate-group forms (80/81/83 with reg field /1 OR, /4 AND,
/// /6 XOR).
///
/// Logical flag rule: **CF = OF = 0**; ZF/SF/PF from the result; AF is
/// architecturally undefined on the 8086 — this core clears it deterministically.
struct LogicalALUTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    @Test("22: AND r8,r/m8 masks bits and sets PF/SF/ZF")
    func andByteRegisters() {
        // MOV AL,0xFC; MOV BL,0x3F; AND AL,BL → 0x3C.
        let machine = machineWithOpcodes([0xB0, 0xFC, 0xB3, 0x3F, 0x22, 0xC3])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.ax & 0xFF == 0x3C)
        let flags = machine.snapshot().cpu.flags
        #expect(flags[.parity])   // 0x3C has four set bits
        #expect(!flags[.sign])
        #expect(!flags[.zero])
        #expect(!flags[.carry])
        #expect(!flags[.overflow])
    }

    @Test("0B: OR r16,r/m16 combines bits and sets SF")
    func orWordRegisters() {
        // MOV AX,0xF000; MOV BX,0x000F; OR AX,BX → 0xF00F.
        let machine = machineWithOpcodes([0xB8, 0x00, 0xF0, 0xBB, 0x0F, 0x00, 0x0B, 0xC3])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.ax == 0xF00F)
        let flags = machine.snapshot().cpu.flags
        #expect(flags[.sign])
        #expect(!flags[.zero])
        #expect(!flags[.carry])
        #expect(!flags[.overflow])
    }

    @Test("31: XOR reg,reg is the idiomatic zeroing (ZF set)")
    func xorZeroingIdiom() {
        // MOV AX,0x1234; XOR AX,AX → 0.
        let machine = machineWithOpcodes([0xB8, 0x34, 0x12, 0x31, 0xC0])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax == 0)
        let flags = machine.snapshot().cpu.flags
        #expect(flags[.zero])
        #expect(!flags[.sign])
        #expect(flags[.parity])   // zero has even (no) parity
    }

    @Test("A logical clears a previously-set CF, OF, and AF")
    func logicalClearsArithmeticCarries() {
        // ADD AL,0x80 when AL=0x80 sets CF, OF, and AF; reload AL and AND it.
        // MOV AL,0x80; ADD AL,0x80 (80 /0); MOV AL,0xFF; MOV BL,0x0F; AND AL,BL.
        let machine = machineWithOpcodes([
            0xB0, 0x80, 0x80, 0xC0, 0x80, 0xB0, 0xFF, 0xB3, 0x0F, 0x22, 0xC3,
        ])
        machine.run(maxSteps: 5)
        #expect(machine.cpu.ax & 0xFF == 0x0F)
        let flags = machine.snapshot().cpu.flags
        #expect(!flags[.carry])
        #expect(!flags[.overflow])
        #expect(!flags[.auxiliaryCarry])
    }

    @Test("80 /4: AND imm8 matches the register form exactly")
    func andImmediateMatchesRegisterForm() {
        // Immediate: MOV AL,0xFC; AND AL,0x3F (80 E0 3F).
        let immediate = machineWithOpcodes([0xB0, 0xFC, 0x80, 0xE0, 0x3F])
        immediate.run(maxSteps: 2)
        // Register: MOV AL,0xFC; MOV BL,0x3F; AND AL,BL.
        let register = machineWithOpcodes([0xB0, 0xFC, 0xB3, 0x3F, 0x22, 0xC3])
        register.run(maxSteps: 3)
        #expect(immediate.cpu.ax & 0xFF == register.cpu.ax & 0xFF)
        #expect(immediate.snapshot().cpu.flags.rawValue == register.snapshot().cpu.flags.rawValue)
    }

    @Test("81 /1: OR r16,imm16")
    func orWordImmediate() {
        // MOV AX,0xF000; OR AX,0x000F (81 C8 0F 00).
        let machine = machineWithOpcodes([0xB8, 0x00, 0xF0, 0x81, 0xC8, 0x0F, 0x00])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax == 0xF00F)
    }

    @Test("83 /6: XOR r16 against a sign-extended imm8 flips all bits")
    func xorImmediateSignExtended() {
        // MOV AX,0x1234; XOR AX,-1 (0xFF → 0xFFFF) via 83 F0 FF → 0xEDCB.
        let machine = machineWithOpcodes([0xB8, 0x34, 0x12, 0x83, 0xF0, 0xFF])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax == 0xEDCB)
    }

    @Test("20: AND r/m8,r8 to a memory destination (read-modify-write)")
    func andToMemory() {
        // Byte 0xFC at DS:0x0080; MOV AL,0x0F; AND [0x0080],AL → 0x0C.
        let machine = machineWithOpcodes([0xB0, 0x0F, 0x20, 0x06, 0x80, 0x00])
        machine.bus.writeByte(0xFC, at: 0x0080)
        machine.run(maxSteps: 2)
        #expect(machine.bus.readByte(at: 0x0080) == 0x0C)
        // MOV 4 + AND reg→mem 16 + direct-address EA 6.
        #expect(machine.snapshot().cycleCount == 26)
    }
}
