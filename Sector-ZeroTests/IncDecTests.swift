import Testing
@testable import Sector_Zero

/// Milestone 16 — INC/DEC reg16 (0x40–0x4F).
///
/// The low three opcode bits index the register. OF/SF/ZF/AF/PF update as
/// for ADD/SUB by 1, but CF is deliberately untouched — the 8086's INC/DEC
/// quirk. 3 clocks each.
struct IncDecTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            let address = (resetVector + UInt32(offset)) & AddressTranslator.physicalAddressMask
            machine.bus.writeByte(opcode, at: address)
        }
        return machine
    }

    @Test("All eight INC encodings increment their register (3 clocks)")
    func allIncEncodings() {
        // INC AX,CX,DX,BX,SP,BP,SI,DI in sequence, all from zero.
        let machine = machineWithOpcodes([0x40, 0x41, 0x42, 0x43, 0x44, 0x45, 0x46, 0x47])
        machine.run(maxSteps: 8)
        #expect(machine.cpu.ax == 1)
        #expect(machine.cpu.cx == 1)
        #expect(machine.cpu.dx == 1)
        #expect(machine.cpu.bx == 1)
        #expect(machine.cpu.sp == 1)
        #expect(machine.cpu.bp == 1)
        #expect(machine.cpu.si == 1)
        #expect(machine.cpu.di == 1)
        #expect(machine.snapshot().cycleCount == 24)
    }

    @Test("All eight DEC encodings decrement their register")
    func allDecEncodings() {
        // MOV each register to 5 first would be long; DEC from zero wraps to
        // 0xFFFF, which exercises the wrap too.
        let machine = machineWithOpcodes([0x48, 0x49, 0x4A, 0x4B, 0x4C, 0x4D, 0x4E, 0x4F])
        machine.run(maxSteps: 8)
        #expect(machine.cpu.ax == 0xFFFF)
        #expect(machine.cpu.cx == 0xFFFF)
        #expect(machine.cpu.dx == 0xFFFF)
        #expect(machine.cpu.bx == 0xFFFF)
        #expect(machine.cpu.sp == 0xFFFF)
        #expect(machine.cpu.bp == 0xFFFF)
        #expect(machine.cpu.si == 0xFFFF)
        #expect(machine.cpu.di == 0xFFFF)
    }

    @Test("INC 0xFFFF wraps to zero, sets ZF, and leaves CF unchanged")
    func incWrapLeavesCarry() {
        // MOV AX,0xFFFF; INC AX. CF starts clear and must stay clear even
        // though the add carried out.
        let machine = machineWithOpcodes([0xB8, 0xFF, 0xFF, 0x40])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax == 0)
        let flags = machine.snapshot().cpu.flags
        #expect(flags[.zero])
        #expect(!flags[.carry])
    }

    @Test("INC preserves a set CF")
    func incPreservesSetCarry() {
        // MOV AL,0xFF; ADD AL,1 sets CF; INC AX must not clear it.
        let machine = machineWithOpcodes([0xB0, 0xFF, 0x80, 0xC0, 0x01, 0x40])
        machine.run(maxSteps: 3)
        #expect(machine.snapshot().cpu.flags[.carry])
    }

    @Test("DEC 0 wraps to 0xFFFF and leaves CF unchanged")
    func decWrapLeavesCarry() {
        // DEC AX from zero: no borrow recorded in CF.
        let machine = machineWithOpcodes([0x48])
        machine.step()
        #expect(machine.cpu.ax == 0xFFFF)
        let flags = machine.snapshot().cpu.flags
        #expect(!flags[.carry])
        #expect(flags[.sign])
    }

    @Test("INC 0x7FFF overflows to 0x8000 (OF and SF set)")
    func incSignedOverflow() {
        let machine = machineWithOpcodes([0xB8, 0xFF, 0x7F, 0x40])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax == 0x8000)
        let flags = machine.snapshot().cpu.flags
        #expect(flags[.overflow])
        #expect(flags[.sign])
        #expect(!flags[.zero])
    }

    @Test("DEC 0x8000 overflows to 0x7FFF (OF set, SF clear)")
    func decSignedOverflow() {
        let machine = machineWithOpcodes([0xB8, 0x00, 0x80, 0x48])
        machine.run(maxSteps: 2)
        #expect(machine.cpu.ax == 0x7FFF)
        let flags = machine.snapshot().cpu.flags
        #expect(flags[.overflow])
        #expect(!flags[.sign])
    }

    @Test("INC updates AF on a low-nibble carry")
    func incAuxiliaryCarry() {
        // MOV AX,0x000F; INC AX → AF set.
        let machine = machineWithOpcodes([0xB8, 0x0F, 0x00, 0x40])
        machine.run(maxSteps: 2)
        #expect(machine.snapshot().cpu.flags[.auxiliaryCarry])
    }

    @Test("A CMP/DEC countdown loop terminates via ZF")
    func decDrivesLoop() {
        // MOV CX,3; loop: DEC CX; JNZ loop; HLT.
        let machine = machineWithOpcodes([0xB9, 0x03, 0x00, 0x49, 0x75, 0xFD, 0xF4])
        machine.run(maxSteps: 20)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.cx == 0)
    }
}
