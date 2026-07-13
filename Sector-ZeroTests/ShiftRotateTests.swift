import Testing
@testable import Sector_Zero

/// Milestone 25 — the 8086 D0–D3 shift/rotate group. CL is deliberately
/// unmasked; undefined AF and multibit OF are preserved deterministically.
struct ShiftRotateTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    @Test("ROL/ROR/RCL/RCR byte forms rotate one bit and define CF/OF")
    func oneBitByteRotates() {
        let rol = ALU.shiftRotate8(0x81, operation: .rotateLeft, count: 1, carryIn: false)
        #expect(rol.result == 0x03)
        #expect(rol.flags.carry == true)
        #expect(rol.flags.overflow == true)

        let ror = ALU.shiftRotate8(0x01, operation: .rotateRight, count: 1, carryIn: false)
        #expect(ror.result == 0x80)
        #expect(ror.flags.carry == true)
        #expect(ror.flags.overflow == true)

        let rcl = ALU.shiftRotate8(0x80, operation: .rotateCarryLeft, count: 1, carryIn: true)
        #expect(rcl.result == 0x01)
        #expect(rcl.flags.carry == true)
        #expect(rcl.flags.overflow == true)

        let rcr = ALU.shiftRotate8(0x01, operation: .rotateCarryRight, count: 1, carryIn: true)
        #expect(rcr.result == 0x80)
        #expect(rcr.flags.carry == true)
        #expect(rcr.flags.overflow == true)

        for outcome in [rol, ror, rcl, rcr] {
            #expect(outcome.flags.sign == nil)
            #expect(outcome.flags.zero == nil)
            #expect(outcome.flags.parity == nil)
        }
    }

    @Test("ROL/ROR/RCL/RCR word forms use a 16/17-bit ring")
    func oneBitWordRotates() {
        let rol = ALU.shiftRotate16(0x8001, operation: .rotateLeft, count: 1, carryIn: false)
        #expect(rol.result == 0x0003)
        #expect(rol.flags.carry == true)
        #expect(rol.flags.overflow == true)

        let ror = ALU.shiftRotate16(0x0001, operation: .rotateRight, count: 1, carryIn: false)
        #expect(ror.result == 0x8000)
        #expect(ror.flags.carry == true)
        #expect(ror.flags.overflow == true)

        let rcl = ALU.shiftRotate16(0x8000, operation: .rotateCarryLeft, count: 1, carryIn: true)
        #expect(rcl.result == 0x0001)
        #expect(rcl.flags.carry == true)

        let rcr = ALU.shiftRotate16(0x0001, operation: .rotateCarryRight, count: 1, carryIn: true)
        #expect(rcr.result == 0x8000)
        #expect(rcr.flags.carry == true)
    }

    @Test("SHL/SHR/SAR byte forms define arithmetic flags for count one")
    func oneBitByteShifts() {
        let shl = ALU.shiftRotate8(0x40, operation: .shiftLeft, count: 1, carryIn: false)
        #expect(shl.result == 0x80)
        #expect(shl.flags.carry == false)
        #expect(shl.flags.overflow == true)
        #expect(shl.flags.sign == true)
        #expect(shl.flags.zero == false)
        #expect(shl.flags.parity == false)

        let shr = ALU.shiftRotate8(0x81, operation: .shiftRight, count: 1, carryIn: false)
        #expect(shr.result == 0x40)
        #expect(shr.flags.carry == true)
        #expect(shr.flags.overflow == true)
        #expect(shr.flags.sign == false)

        let sar = ALU.shiftRotate8(0x81, operation: .shiftArithmeticRight, count: 1, carryIn: false)
        #expect(sar.result == 0xC0)
        #expect(sar.flags.carry == true)
        #expect(sar.flags.overflow == false)
        #expect(sar.flags.sign == true)
        #expect(sar.flags.parity == true)
    }

    @Test("SHL/SHR/SAR word forms use bit 15 and low-byte parity")
    func oneBitWordShifts() {
        let shl = ALU.shiftRotate16(0x4000, operation: .shiftLeft, count: 1, carryIn: false)
        #expect(shl.result == 0x8000)
        #expect(shl.flags.overflow == true)
        #expect(shl.flags.sign == true)
        #expect(shl.flags.parity == true) // low byte is zero

        let shr = ALU.shiftRotate16(0x8001, operation: .shiftRight, count: 1, carryIn: false)
        #expect(shr.result == 0x4000)
        #expect(shr.flags.carry == true)
        #expect(shr.flags.overflow == true)

        let sar = ALU.shiftRotate16(0x8001, operation: .shiftArithmeticRight, count: 1, carryIn: false)
        #expect(sar.result == 0xC000)
        #expect(sar.flags.carry == true)
        #expect(sar.flags.overflow == false)
    }

    @Test("RCL returns after 9/17 bits and includes carry in the ring")
    func rotateThroughCarryRingWidth() {
        let byte = ALU.shiftRotate8(0xA5, operation: .rotateCarryLeft, count: 9, carryIn: true)
        #expect(byte.result == 0xA5)
        #expect(byte.flags.carry == true)
        #expect(byte.flags.overflow == nil)

        let word = ALU.shiftRotate16(0xBEEF, operation: .rotateCarryLeft, count: 17, carryIn: true)
        #expect(word.result == 0xBEEF)
        #expect(word.flags.carry == true)
        #expect(word.flags.overflow == nil)
    }

    @Test("A CL count of zero leaves operand and every flag unchanged")
    func zeroCountChangesNothing() {
        // Seed FLAGS via POPF, set BL, set CL=0, then SHL BL,CL.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0xB8, 0xD5, 0x0E, 0x50, 0x9D, // TF clear; trap delivery is tested in M35
            0xB3, 0x81,
            0xB1, 0x00,
            0xD2, 0xE3,
        ])
        machine.run(maxSteps: 6)
        let before = machine.cpu.flags
        machine.step()

        #expect(machine.cpu.registers[.bl] == 0x81)
        #expect(machine.cpu.flags == before)
        #expect(machine.cycleCount == 43) // setup 35 + CL-count base 8
    }

    @Test("The 8086 uses all eight CL bits and charges 4 clocks per bit")
    func clCountIsUnmasked() {
        // MOV AL,1; MOV CL,255; SHL AL,CL.
        let machine = machineWithOpcodes([0xB0, 0x01, 0xB1, 0xFF, 0xD2, 0xE0])
        machine.run(maxSteps: 3)

        #expect(machine.cpu.registers[.al] == 0x00)
        #expect(machine.cpu.flags[.zero])
        #expect(!machine.cpu.flags[.carry])
        #expect(machine.cycleCount == 1_036) // MOVs 8 + (8 + 4×255)
    }

    @Test("Multibit OF and undefined AF are preserved deterministically")
    func undefinedFlagsArePreserved() {
        // Seed OF+AF, load AL/CL without touching flags, then SHL AL,CL by 2.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0xB8, 0x10, 0x08, 0x50, 0x9D,
            0xB0, 0x20,
            0xB1, 0x02,
            0xD2, 0xE0,
        ])
        machine.run(maxSteps: 7)

        #expect(machine.cpu.registers[.al] == 0x80)
        #expect(machine.cpu.flags[.overflow])
        #expect(machine.cpu.flags[.auxiliaryCarry])
        #expect(machine.cpu.flags[.sign])
    }

    @Test("D1 memory shift is read-modify-write at 15+EA clocks")
    func memoryShiftTiming() {
        // SHL word [0040],1; direct-address EA is 6 clocks.
        let machine = machineWithOpcodes([0xD1, 0x26, 0x40, 0x00])
        machine.bus.writeByte(0x00, at: 0x0040)
        machine.bus.writeByte(0x40, at: 0x0041)
        machine.step()

        #expect(machine.bus.readByte(at: 0x0040) == 0x00)
        #expect(machine.bus.readByte(at: 0x0041) == 0x80)
        #expect(machine.cycleCount == 21)
    }

    @Test("Segment override redirects a shift's memory operand")
    func memoryShiftHonorsOverride() {
        // ES: SHL byte [0040],1.
        let machine = machineWithOpcodes([0x26, 0xD0, 0x26, 0x40, 0x00])
        machine.cpu.writeSegment(0x2000, to: .es)
        machine.bus.writeByte(0x40, at: 0x20040)
        machine.bus.writeByte(0x11, at: 0x00040)
        machine.step()

        #expect(machine.bus.readByte(at: 0x20040) == 0x80)
        #expect(machine.bus.readByte(at: 0x00040) == 0x11)
        #expect(machine.cycleCount == 23) // prefix 2 + shift 15+EA 6
    }

    @Test("Every defined selector decodes for D0–D3")
    func decodesEveryForm() {
        let decoder = InstructionDecoder()
        let selectors: [ShiftRotateOperation] = [
            .rotateLeft, .rotateRight, .rotateCarryLeft, .rotateCarryRight,
            .shiftLeft, .shiftRight, .shiftArithmeticRight,
        ]

        for opcode in UInt8(0xD0)...UInt8(0xD3) {
            for operation in selectors {
                let modRM = UInt8(0xC0) | (operation.rawValue << 3)
                let count: ShiftCount = opcode & 0b10 == 0 ? .one : .cl
                let expected: Instruction = opcode & 1 == 0
                    ? .shiftRotate8(operation: operation, destination: .register(0), count: count, eaClocks: 0)
                    : .shiftRotate16(operation: operation, destination: .register(0), count: count, eaClocks: 0)
                #expect(decoder.decode(opcode: opcode, registers: RegisterFile()) { modRM } == expected)
            }
        }
    }

    @Test("Undefined /6 consumes ModR/M and displacement before faulting")
    func undefinedSelectorStaysAligned() {
        // D1 /6 direct-address consumes four bytes; M39 stops at the gap.
        let machine = machineWithOpcodes([0xD1, 0x36, 0x40, 0x00, 0xF4])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ip == 4)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.fault == .unsupportedOpcode(0xD1))
    }
}
