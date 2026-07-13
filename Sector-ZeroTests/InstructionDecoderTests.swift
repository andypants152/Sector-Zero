import Testing
@testable import Sector_Zero

/// Milestone 3 — instruction decoding.
///
/// The decoder turns a fetched opcode byte into a typed `Instruction` without
/// executing anything. Only the single-byte opcodes NOP (0x90) and HLT (0xF4)
/// are recognised; everything else decodes to `.unknown`. Decoding is pure —
/// it touches no CPU or machine state, and no operand bytes exist yet, so the
/// byte reader must never be called.
struct InstructionDecoderTests {
    private let decoder = InstructionDecoder()

    /// A byte reader that fails the test if the decoder asks for operand bytes,
    /// which no currently-decoded instruction requires.
    private func forbiddenReader() -> () -> UInt8 {
        {
            Issue.record("Decoder requested an operand byte for an instruction that has none")
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
        UInt8(0x04), 0x0F, 0x27, 0x87, 0x91, 0xAF, 0xC0, 0xF3, 0xF5, 0xFF,
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
        let operandOpcodes: Set<ClosedRange<UInt8>> = [
            0x00...0x03, 0x28...0x2B, 0x38...0x3B, 0x70...0x7F,
            0x80...0x81, 0x83...0x83, 0x88...0x8B, 0xB0...0xBF,
            0xE0...0xE3, 0xE8...0xE8, 0xEB...0xEB,
        ]
        for opcode in UInt8.min...UInt8.max where !operandOpcodes.contains(where: { $0.contains(opcode) }) {
            _ = decoder.decode(opcode: opcode, registers: RegisterFile(), nextByte: forbiddenReader())
        }
    }

    @Test("Decoding does not mutate CPU or machine state")
    func decodingIsPure() {
        let machine = Machine()
        let before = machine.snapshot()
        _ = decoder.decode(opcode: 0x90, registers: RegisterFile(), nextByte: forbiddenReader())
        _ = decoder.decode(opcode: 0xF4, registers: RegisterFile(), nextByte: forbiddenReader())
        _ = decoder.decode(opcode: 0xAB, registers: RegisterFile(), nextByte: forbiddenReader())
        let after = machine.snapshot()
        #expect(after.cpu.ip == before.cpu.ip)
        #expect(after.cpu.lastFetchedOpcode == before.cpu.lastFetchedOpcode)
        #expect(after.cycleCount == before.cycleCount)
    }

    @Test("Decoding the same byte sequence twice yields the same instruction")
    func decodingIsDeterministic() {
        for opcode in UInt8.min...UInt8.max {
            // Long enough for the longest decode (0x81 mod=00 r/m=110:
            // ModR/M + disp16 + imm16 = 5 bytes).
            var firstStream: [UInt8] = [0x34, 0x12, 0x56, 0x78, 0x9A]
            var secondStream: [UInt8] = [0x34, 0x12, 0x56, 0x78, 0x9A]
            let first = decoder.decode(opcode: opcode, registers: RegisterFile()) { firstStream.removeFirst() }
            let second = decoder.decode(opcode: opcode, registers: RegisterFile()) { secondStream.removeFirst() }
            #expect(first == second)
        }
    }
}
