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
        case 0xB0...0xB7:
            // MOV reg8, imm8 — the low three opcode bits are the register
            // encoding, which Register8's raw values mirror.
            let register = Register8(rawValue: opcode & 0b111)!
            return .movImmediateToRegister8(register, nextByte())
        case 0xB8...0xBF:
            // MOV reg16, imm16 — immediate is little-endian in the stream.
            let register = Register16(rawValue: opcode & 0b111)!
            let low = nextByte()
            let high = nextByte()
            return .movImmediateToRegister16(register, UInt16(high) << 8 | UInt16(low))
        default:
            return .unknown(opcode)
        }
    }
}
