import Testing
@testable import Sector_Zero

/// Milestone 3 — instruction decoding.
///
/// The decoder turns a fetched opcode byte into a typed `Instruction` without
/// executing it. Operand-bearing instructions pull immediates, ModR/M bytes,
/// and displacements through `nextByte`; operand-free instructions must not
/// touch the reader. Decoding is pure: it can read the register file to resolve
/// effective addresses, but it must not mutate register or machine state.
struct InstructionDecoderTests {
    private let decoder = InstructionDecoder()

    /// A byte reader for opcodes that should not request operand bytes.
    private func forbiddenReader() -> () -> UInt8 {
        {
            Issue.record("Decoder requested an operand byte for an operand-free instruction")
            return 0
        }
    }

    @Test("0x90 decodes to NOP")
    func decodesNOP() {
        #expect(decoder.decode(opcode: 0x90, registers: RegisterFile(), nextByte: forbiddenReader()) == .nop)
    }

    @Test("0xF4 decodes to HLT")
    func decodesHLT() {
        #expect(decoder.decode(opcode: 0xF4, registers: RegisterFile(), nextByte: forbiddenReader()) == .hlt)
    }

    @Test("Unrecognised opcodes decode to .unknown carrying the byte", arguments: [
        UInt8(0x60), 0x61, 0x27, 0x62, 0x64, 0xAF, 0xC0, 0xF3, 0xF5, 0xFF,
    ])
    func decodesUnknown(opcode: UInt8) {
        #expect(decoder.decode(opcode: opcode, registers: RegisterFile(), nextByte: forbiddenReader()) == .unknown(opcode))
    }

    @Test("Opcodes without operands decode without consuming bytes")
    func decodingConsumesNoOperandBytes() {
        // ADD/SUB/CMP (00–03, 28–2B, 38–3B), the immediate ALU group
        // (80/81/83), and MOV (88–8B) pull ModR/M bytes; MOV imm (B0–BF) and
        // the ALU group pull immediates; jumps (70–7F, EB) and CALL (E8)
        // pull displacements.
        // ALU ranges now cover the accumulator-immediate forms too, so each
        // op's r/m↔reg block and its acc form merge (e.g. ADD 0x00–0x05); the
        // ADC/SBB accumulator forms (0x14/0x15, 0x1C/0x1D) still pull their
        // immediate before decoding to .unknown.
        let operandOpcodes: Set<ClosedRange<UInt8>> = [
            0x00...0x05, 0x08...0x0D, 0x14...0x15, 0x1C...0x1D,
            0x20...0x25, 0x28...0x2D, 0x30...0x35, 0x38...0x3D,
            0x70...0x7F, 0x80...0x81, 0x83...0x8C, 0x8E...0x8E, 0xA0...0xA3,
            0xA8...0xA9, 0xB0...0xBF, 0xC6...0xC7, 0xE0...0xE3, 0xE8...0xEB,
        ]
        for opcode in UInt8.min...UInt8.max where !operandOpcodes.contains(where: { $0.contains(opcode) }) {
            _ = decoder.decode(opcode: opcode, registers: RegisterFile(), nextByte: forbiddenReader())
        }
    }

    @Test("Decoding does not mutate the register file")
    func decodingIsPure() {
        var registers = RegisterFile()
        registers[.bx] = 0x1000
        registers[.si] = 0x0004
        let before = registers

        var stream: [UInt8] = [0x00] // ModR/M: mod=00 reg=000 r/m=000 => [BX+SI]
        _ = decoder.decode(opcode: 0x8A, registers: registers) {
            stream.removeFirst()
        }

        #expect(registers == before)
    }

    @Test("Decoding the same byte sequence twice yields the same instruction")
    func decodingIsDeterministic() {
        for opcode in UInt8.min...UInt8.max {
            // Long enough for the longest decode: 0x81 or 0xC7 mod=00 r/m=110
            // pulls ModR/M + disp16 + imm16 = 5 bytes. One byte of headroom.
            var firstStream: [UInt8] = [0x34, 0x12, 0x56, 0x78, 0x9A, 0xBC]
            var secondStream: [UInt8] = [0x34, 0x12, 0x56, 0x78, 0x9A, 0xBC]
            let first = decoder.decode(opcode: opcode, registers: RegisterFile()) { firstStream.removeFirst() }
            let second = decoder.decode(opcode: opcode, registers: RegisterFile()) { secondStream.removeFirst() }
            #expect(first == second)
        }
    }
}
