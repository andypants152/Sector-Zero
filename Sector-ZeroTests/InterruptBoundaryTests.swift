import Testing
@testable import Sector_Zero

/// Milestone 35 — processor-generated and external interrupt boundaries.
struct InterruptBoundaryTests {
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

    private func writeWord(_ value: UInt16, at address: UInt32, to machine: Machine) {
        machine.bus.writeByte(UInt8(truncatingIfNeeded: value), at: address)
        machine.bus.writeByte(UInt8(value >> 8), at: address + 1)
    }

    private func installVector(_ type: UInt8, offset: UInt16, segment: UInt16, in machine: Machine) {
        let address = UInt32(type) * 4
        writeWord(offset, at: address, to: machine)
        writeWord(segment, at: address + 2, to: machine)
    }

    private func set(_ register: Register16, to value: UInt16, on cpu: CPU8086) {
        _ = cpu.execute(.movImmediateToRegister16(register, value))
    }

    @Test("Divide error saves the following 8086 IP and IRET continues")
    func divideErrorReturnAddress() {
        // MOV SP,0100; MOV AX,1234; MOV BL,0; DIV BL; HLT.
        let machine = machineWithOpcodes([
            0xBC, 0x00, 0x01,
            0xB8, 0x34, 0x12,
            0xB3, 0x00,
            0xF6, 0xF3,
            0xF4,
        ])
        installVector(0, offset: 0, segment: 0x1000, in: machine)
        machine.bus.writeByte(0xCF, at: 0x10000)

        machine.run(maxSteps: 4)

        #expect(machine.cpu.cs == 0x1000)
        #expect(machine.cpu.ip == 0)
        #expect(machine.cpu.sp == 0x00FA)
        #expect(machine.bus.readWord(at: 0x00FA) == 0x000A)
        #expect(machine.bus.readWord(at: 0x00FC) == 0xFFFF)
        #expect(machine.cpu.ax == 0x1234)
        #expect(machine.cpu.fault == nil)

        machine.run(maxSteps: 2)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.cs == 0xFFFF)
        #expect(machine.cpu.ip == 0x000B)
        #expect(machine.cpu.sp == 0x0100)
    }

    @Test("TF delivers vector 1 after the instruction with its following IP")
    func singleStepTrap() {
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0x90])
        installVector(1, offset: 0x0100, segment: 0x2000, in: machine)
        machine.step()
        _ = machine.cpu.execute(.setFlag(.trap))

        machine.step()

        #expect(machine.cpu.cs == 0x2000)
        #expect(machine.cpu.ip == 0x0100)
        #expect(machine.cpu.sp == 0x00FA)
        #expect(machine.bus.readWord(at: 0x00FA) == 0x0004)
        #expect(machine.bus.readWord(at: 0x00FC) == 0xFFFF)
        #expect(machine.bus.readWord(at: 0x00FE) & CPUFlag.trap.mask != 0)
        #expect(!machine.cpu.flags[.trap])
        #expect(machine.cycleCount == 57) // MOV 4 + NOP 3 + trap 50
    }

    @Test("NMI outranks INTR, which remains pending until IRET restores IF")
    func externalPriorityAndMasking() {
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0x90])
        installVector(2, offset: 0, segment: 0x1000, in: machine)
        installVector(0x20, offset: 0, segment: 0x2000, in: machine)
        machine.bus.writeByte(0xCF, at: 0x10000)
        machine.step()
        _ = machine.cpu.execute(.setFlag(.interruptEnable))
        machine.requestINTR(vector: 0x20)
        machine.requestNMI()

        machine.step()
        #expect(machine.cpu.cs == 0x1000)
        #expect(machine.cpu.ip == 0)
        #expect(!machine.cpu.flags[.interruptEnable])

        // IRET restores IF, then the still-pending INTR is accepted at that
        // same completed-instruction boundary before any main-line fetch.
        machine.step()
        #expect(machine.cpu.cs == 0x2000)
        #expect(machine.cpu.ip == 0)
        #expect(machine.cpu.sp == 0x00FA)
        #expect(machine.cycleCount == 139) // MOV 4 + NMI 50 + IRET 24 + INTR 61
    }

    @Test("STI delays a pending INTR through the following instruction")
    func stiShadow() {
        // MOV SP,0100; STI; NOP.
        let machine = machineWithOpcodes([0xBC, 0x00, 0x01, 0xFB, 0x90])
        installVector(0x20, offset: 0, segment: 0x3000, in: machine)
        machine.step()
        machine.requestINTR(vector: 0x20)

        machine.step()
        #expect(machine.cpu.cs == 0xFFFF)
        #expect(machine.cpu.ip == 4)

        machine.step()
        #expect(machine.cpu.cs == 0x3000)
        #expect(machine.cpu.ip == 0)
        #expect(machine.bus.readWord(at: 0x00FA) == 0x0005)
        #expect(machine.cycleCount == 70) // MOV 4 + STI 2 + NOP 3 + INTR 61
    }

    @Test("MOV SS and POP SS inhibit interrupts through the next instruction")
    func stackSegmentShadows() {
        // MOV AX,1000; MOV SS,AX; NOP.
        let moved = machineWithOpcodes([0xB8, 0x00, 0x10, 0x8E, 0xD0, 0x90])
        installVector(0x20, offset: 0, segment: 0x3000, in: moved)
        moved.run(maxSteps: 2)
        _ = moved.cpu.execute(.setFlag(.interruptEnable))
        moved.requestINTR(vector: 0x20)
        moved.step()
        #expect(moved.cpu.cs == 0x3000)
        #expect(moved.bus.readWord(at: physical(0x1000, 0xFFFA)) == 0x0006)

        // MOV SP,0100; POP SS; NOP.
        let popped = machineWithOpcodes([0xBC, 0x00, 0x01, 0x17, 0x90])
        installVector(0x21, offset: 0, segment: 0x4000, in: popped)
        writeWord(0x2000, at: 0x0100, to: popped)
        popped.run(maxSteps: 2)
        _ = popped.cpu.execute(.setFlag(.interruptEnable))
        popped.requestINTR(vector: 0x21)
        popped.step()
        #expect(popped.cpu.cs == 0x4000)
        #expect(popped.bus.readWord(at: physical(0x2000, 0x00FC)) == 0x0005)
    }

    @Test("Masked INTR leaves HLT asleep; NMI wakes it")
    func haltWake() {
        let machine = machineWithOpcodes([0xF4])
        installVector(2, offset: 0x0100, segment: 0x5000, in: machine)
        machine.step()
        let haltedCycles = machine.cycleCount

        machine.requestINTR(vector: 0x20)
        machine.step()
        #expect(machine.cpu.halted)
        #expect(machine.cycleCount == haltedCycles)

        machine.requestNMI()
        machine.step()
        #expect(!machine.cpu.halted)
        #expect(machine.cpu.cs == 0x5000)
        #expect(machine.cpu.ip == 0x0100)
        #expect(machine.cycleCount == 52) // HLT 2 + NMI 50
    }

    @Test("An interrupt between REP iterations resumes without repeating work")
    func interruptAndResumeRepeat() {
        // STI; REP MOVSB; HLT. STI's shadow lets the first move complete before
        // the already-pending INTR is recognized.
        let machine = machineWithOpcodes([0xFB, 0xF3, 0xA4, 0xF4])
        installVector(0x20, offset: 0, segment: 0x3000, in: machine)
        machine.bus.writeByte(0xCF, at: 0x30000)
        machine.cpu.writeSegment(0x1000, to: .ds)
        machine.cpu.writeSegment(0x2000, to: .es)
        set(.sp, to: 0x0100, on: machine.cpu)
        set(.cx, to: 3, on: machine.cpu)
        for (offset, value) in [UInt8(0x11), 0x22, 0x33].enumerated() {
            machine.bus.writeByte(value, at: physical(0x1000, UInt16(offset)))
        }
        machine.requestINTR(vector: 0x20)

        machine.step() // STI
        machine.step() // One MOVSB, then INTR.
        #expect(machine.cpu.cs == 0x3000)
        #expect(machine.cpu.cx == 2)
        #expect(machine.cpu.si == 1)
        #expect(machine.cpu.di == 1)
        #expect(machine.bus.readByte(at: physical(0x2000, 0)) == 0x11)
        #expect(machine.bus.readWord(at: 0x00FA) == 0x0001) // REP prefix restart IP

        machine.step() // IRET to the suspended REP.
        #expect(machine.cpu.cs == 0xFFFF)
        #expect(machine.cpu.ip == 1)

        machine.step() // Resume the remaining two iterations.
        #expect(machine.cpu.cx == 0)
        #expect(machine.cpu.si == 3)
        #expect(machine.cpu.di == 3)
        #expect(machine.cpu.ip == 3)
        #expect(machine.bus.readByte(at: physical(0x2000, 0)) == 0x11)
        #expect(machine.bus.readByte(at: physical(0x2000, 1)) == 0x22)
        #expect(machine.bus.readByte(at: physical(0x2000, 2)) == 0x33)
        #expect(machine.cycleCount == 156)
    }
}
