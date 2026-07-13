import Foundation

/// Translates fetched opcode bytes into typed `Instruction` values.
///
/// Decoding is pure: it never touches registers, memory, or flags. The
/// `nextByte` reader is the boundary through which operand-bearing
/// instructions (immediates, ModR/M, displacements) will pull additional
/// bytes from the code stream in later milestones; the opcodes decoded today
/// are single-byte, so it is never invoked yet.
struct InstructionDecoder {
    func decode(opcode: UInt8, nextByte: () -> UInt8) -> Instruction {
        switch opcode {
        case 0x90:
            return .nop
        case 0xF4:
            return .hlt
        default:
            return .unknown(opcode)
        }
    }
}
