import Testing
@testable import Sector_Zero

/// Milestone 12 — conditional jumps (0x70–0x7F) and JMP short (0xEB).
///
/// All sixteen Jcc opcodes carry a signed 8-bit displacement relative to the
/// next instruction (IP has already passed the operand when it is applied).
/// The low opcode bit inverts the base predicate; JL/JLE use SF≠OF.
/// Cycles: 16 taken / 4 not taken; JMP short is 15, always taken.
struct JumpTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(opcodes, at: resetVector)
        return machine
    }

    private func flags(_ set: [CPUFlag]) -> CPUFlags {
        var flags = CPUFlags()
        for flag in set { flags[flag] = true }
        return flags
    }

    // MARK: Predicates

    @Test("Each condition encoding matches its documented flag predicate")
    func predicateTable() {
        // (encoding, flags to set, expected taken)
        let vectors: [(UInt8, [CPUFlag], Bool)] = [
            (0x0, [.overflow], true), (0x0, [], false),                      // JO
            (0x1, [.overflow], false), (0x1, [], true),                      // JNO
            (0x2, [.carry], true), (0x2, [], false),                         // JB
            (0x3, [.carry], false), (0x3, [], true),                         // JNB
            (0x4, [.zero], true), (0x4, [], false),                          // JZ
            (0x5, [.zero], false), (0x5, [], true),                          // JNZ
            (0x6, [.carry], true), (0x6, [.zero], true), (0x6, [], false),   // JBE
            (0x7, [.carry], false), (0x7, [], true),                         // JNBE
            (0x8, [.sign], true), (0x8, [], false),                          // JS
            (0x9, [.sign], false), (0x9, [], true),                          // JNS
            (0xA, [.parity], true), (0xA, [], false),                        // JP
            (0xB, [.parity], false), (0xB, [], true),                        // JNP
            (0xC, [.sign], true), (0xC, [.overflow], true),                  // JL: SF≠OF
            (0xC, [.sign, .overflow], false), (0xC, [], false),
            (0xD, [.sign], false), (0xD, [.sign, .overflow], true), (0xD, [], true), // JNL
            (0xE, [.zero], true), (0xE, [.sign], true),                      // JLE: ZF or SF≠OF
            (0xE, [.sign, .overflow], false), (0xE, [], false),
            (0xF, [.zero], false), (0xF, [.sign, .overflow], true), (0xF, [], true), // JNLE
        ]
        for (encoding, set, expected) in vectors {
            let condition = JumpCondition(encoding: encoding)
            #expect(
                condition.isSatisfied(by: flags(set)) == expected,
                "encoding \(encoding) with \(set) should be \(expected)"
            )
        }
    }

    // MARK: Taken / not taken

    @Test("A taken Jcc adds the displacement and costs 16 cycles")
    func takenJump() {
        // CMP AL, AL sets ZF; JZ +2 skips MOV AL, 0xFF.
        let machine = machineWithOpcodes([0x38, 0xC0, 0x74, 0x02, 0xB0, 0xFF, 0xF4])
        machine.run(maxSteps: 10)
        #expect(machine.cpu.registers[.al] == 0x00)
        #expect(machine.cpu.halted)
        // CMP reg 3 + JZ taken 16 + HLT 2.
        #expect(machine.snapshot().cycleCount == 21)
    }

    @Test("A not-taken Jcc falls through and costs 4 cycles")
    func notTakenJump() {
        // CMP AL, AL sets ZF; JNZ +2 must NOT skip MOV AL, 0xFF.
        let machine = machineWithOpcodes([0x38, 0xC0, 0x75, 0x02, 0xB0, 0xFF, 0xF4])
        machine.run(maxSteps: 10)
        #expect(machine.cpu.registers[.al] == 0xFF)
        #expect(machine.cpu.halted)
        // CMP 3 + JNZ not taken 4 + MOV 4 + HLT 2.
        #expect(machine.snapshot().cycleCount == 13)
    }

    // MARK: Loops

    @Test("A CMP/SUB + JNZ countdown loop terminates with the right trip count")
    func countdownLoop() {
        // MOV CL, 3; MOV BL, 1; loop: SUB CL, BL (28 D9); JNZ loop; HLT.
        let machine = machineWithOpcodes([0xB1, 0x03, 0xB3, 0x01, 0x28, 0xD9, 0x75, 0xFC, 0xF4])
        machine.run(maxSteps: 50)
        #expect(machine.cpu.registers[.cl] == 0x00)
        #expect(machine.cpu.halted)
        // 4+4 (MOVs) + 3×3 (SUBs) + 2×16 (taken) + 4 (final not-taken) + 2 (HLT).
        #expect(machine.snapshot().cycleCount == 55)
    }

    // MARK: JMP short

    @Test("EB jumps unconditionally forward for 15 cycles")
    func jmpShortForward() {
        // JMP +2 over MOV AL, 0xFF.
        let machine = machineWithOpcodes([0xEB, 0x02, 0xB0, 0xFF, 0xF4])
        machine.run(maxSteps: 10)
        #expect(machine.cpu.registers[.al] == 0x00)
        #expect(machine.cpu.halted)
        #expect(machine.snapshot().cycleCount == 17) // 15 + HLT 2
    }

    @Test("Backward displacement is sign-extended (IP wraps at 16 bits)")
    func jmpShortBackwardWraps() {
        // At reset IP=0; after fetching EB F0, IP=2; 2 + (-16) wraps to 0xFFF2.
        let machine = machineWithOpcodes([0xEB, 0xF0])
        machine.step()
        #expect(machine.cpu.ip == 0xFFF2)
    }

    @Test("Displacement is relative to the next instruction")
    func displacementRelativeToNextInstruction() {
        // JMP +0 is a two-byte no-op: execution continues at the next byte.
        let machine = machineWithOpcodes([0xEB, 0x00, 0xF4])
        machine.run(maxSteps: 5)
        #expect(machine.cpu.halted)
        #expect(machine.cpu.ip == 0x0003)
    }
}
