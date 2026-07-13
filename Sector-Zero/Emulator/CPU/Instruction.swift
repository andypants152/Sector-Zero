import Foundation

/// A decoded 8086 instruction, independent of how its bytes were fetched.
///
/// Milestone 3 covers only the single-byte opcodes NOP and HLT; any other
/// opcode decodes to `.unknown` carrying the raw byte so callers can surface
/// or trap it. Operand-bearing cases (immediates, ModR/M) will be added as
/// later milestones land.
enum Instruction: Equatable {
    case nop
    case hlt
    case unknown(UInt8)
}
