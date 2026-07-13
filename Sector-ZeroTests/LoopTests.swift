import Testing
@testable import Sector_Zero

/// Milestone 17 — LOOP family + JCXZ (0xE0–0xE3).
///
/// LOOP (E2) decrements CX without touching flags and branches while CX ≠ 0;
/// LOOPE/LOOPZ (E1) additionally requires ZF set, LOOPNE/LOOPNZ (E0) ZF
/// clear. JCXZ (E3) branches when CX == 0 and never modifies it. All take a
/// signed disp8 relative to the next instruction. Cycles (taken/not-taken):
/// LOOP 17/5, LOOPE 18/6, LOOPNE 19/5, JCXZ 18/6.
struct LoopTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    @Test("E2: LOOP counts CX down to zero and falls through")
    func loopCountdown() {
        // MOV CX,3; loop: INC AX; LOOP loop; HLT.
        let machine = machineWithOpcodes([0xB9, 0x03, 0x00, 0x40, 0xE2, 0xFD, 0xF4])
        machine.run(maxSteps: 20)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.cx == 0)
        #expect(machine.cpu.ax == 3)
    }

    @Test("E2: LOOP decrements CX without touching flags")
    func loopLeavesFlags() {
        // MOV AL,0xFF; ADD AL,1 → CF and ZF set; MOV CX,2; LOOP -2 (spins on
        // itself once); flags must survive both LOOP executions.
        let machine = machineWithOpcodes([0xB0, 0xFF, 0x80, 0xC0, 0x01, 0xB9, 0x02, 0x00, 0xE2, 0xFE])
        let machine2 = machineWithOpcodes([0xB0, 0xFF, 0x80, 0xC0, 0x01])
        machine.run(maxSteps: 5)
        machine2.run(maxSteps: 2)
        #expect(machine.snapshot().cpu.flags.rawValue == machine2.snapshot().cpu.flags.rawValue)
        #expect(machine.cpu.cx == 0)
    }

    @Test("E2: taken LOOP is 17 clocks, not-taken 5")
    func loopCycles() {
        // MOV CX,2; LOOP -2: first LOOP taken (CX 1), second not (CX 0).
        let machine = machineWithOpcodes([0xB9, 0x02, 0x00, 0xE2, 0xFE])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.cx == 0)
        // MOV 4 + 17 + 5.
        #expect(machine.snapshot().cycleCount == 26)
    }

    @Test("E2: LOOP entered with CX=0 wraps to 0xFFFF and takes the branch")
    func loopWrapsFromZero() {
        // LOOP +0 with CX=0 at reset: decrement wraps to 0xFFFF ≠ 0 → taken.
        let machine = machineWithOpcodes([0xE2, 0x00])
        machine.step()
        #expect(machine.cpu.cx == 0xFFFF)
        #expect(machine.snapshot().cycleCount == 17) // taken
    }

    @Test("E1: LOOPE only branches while ZF is set")
    func loopWhileEqual() {
        // MOV CX,2; CMP AL,0 via 80 /7 (AL=0 → ZF set); LOOPE -2 spins on
        // itself: ZF stays set, so it loops until CX hits 0.
        let machine = machineWithOpcodes([0xB9, 0x02, 0x00, 0x80, 0xF8, 0x00, 0xE1, 0xFE])
        machine.run(maxSteps: 5)
        #expect(machine.cpu.cx == 0)

        // Same but ZF clear (CMP AL,1): first LOOPE already falls through.
        let notEqual = machineWithOpcodes([0xB9, 0x02, 0x00, 0x80, 0xF8, 0x01, 0xE1, 0xFE])
        notEqual.run(maxSteps: 3)
        #expect(notEqual.cpu.cx == 1) // decremented once, branch not taken
    }

    @Test("E0: LOOPNE only branches while ZF is clear")
    func loopWhileNotEqual() {
        // ZF clear → spins until CX exhausts.
        let machine = machineWithOpcodes([0xB9, 0x02, 0x00, 0x80, 0xF8, 0x01, 0xE0, 0xFE])
        machine.run(maxSteps: 5)
        #expect(machine.cpu.cx == 0)

        // ZF set → falls through immediately (but still decrements).
        let equal = machineWithOpcodes([0xB9, 0x02, 0x00, 0x80, 0xF8, 0x00, 0xE0, 0xFE])
        equal.run(maxSteps: 3)
        #expect(equal.cpu.cx == 1)
    }

    @Test("E1/E0 cycles: LOOPE 18/6, LOOPNE 19/5")
    func conditionalLoopCycles() {
        // MOV CX,1; LOOPE -2 with ZF clear (reset flags): not taken → 6.
        let loope = machineWithOpcodes([0xB9, 0x01, 0x00, 0xE1, 0xFE])
        loope.run(maxSteps: 2)
        #expect(loope.snapshot().cycleCount == 10) // 4 + 6

        // MOV CX,2; LOOPNE -2 with ZF clear: taken then not → 19 + 5.
        let loopne = machineWithOpcodes([0xB9, 0x02, 0x00, 0xE0, 0xFE])
        loopne.run(maxSteps: 3)
        #expect(loopne.snapshot().cycleCount == 28) // 4 + 19 + 5
    }

    @Test("E3: JCXZ branches when CX is zero and leaves CX alone")
    func jcxzTaken() {
        // CX=0 at reset; JCXZ +1 skips the HLT and runs INC AX; HLT.
        let machine = machineWithOpcodes([0xE3, 0x01, 0xF4, 0x40, 0xF4])
        machine.run(maxSteps: 5)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.ax == 1)
        #expect(machine.cpu.cx == 0)
    }

    @Test("E3: JCXZ falls through when CX is nonzero (18/6 clocks)")
    func jcxzNotTaken() {
        // MOV CX,1; JCXZ +1; HLT — branch not taken, halt reached.
        let machine = machineWithOpcodes([0xB9, 0x01, 0x00, 0xE3, 0x01, 0xF4, 0x40])
        machine.run(maxSteps: 3)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.ax == 0)
        #expect(machine.cpu.cx == 1)
        // MOV 4 + JCXZ not-taken 6 + HLT 2.
        #expect(machine.snapshot().cycleCount == 12)

        // Taken cost: JCXZ +0 with CX=0 → 18.
        let taken = machineWithOpcodes([0xE3, 0x00])
        taken.step()
        #expect(taken.snapshot().cycleCount == 18)
    }
}
