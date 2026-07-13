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
        #expect(decoder.decode(opcode: 0x90, nextByte: forbiddenReader()) == .nop)
    }

    @Test("0xF4 decodes to HLT")
    func decodesHLT() {
        #expect(decoder.decode(opcode: 0xF4, nextByte: forbiddenReader()) == .hlt)
    }

    @Test("Unrecognised opcodes decode to .unknown carrying the byte", arguments: [
        UInt8(0x00), 0x0F, 0x42, 0x8B, 0x91, 0xB8, 0xF3, 0xF5, 0xFF,
    ])
    func decodesUnknown(opcode: UInt8) {
        #expect(decoder.decode(opcode: opcode, nextByte: forbiddenReader()) == .unknown(opcode))
    }

    @Test("Every opcode decodes without consuming operand bytes")
    func decodingConsumesNoOperandBytes() {
        for opcode in UInt8.min...UInt8.max {
            _ = decoder.decode(opcode: opcode, nextByte: forbiddenReader())
        }
    }

    @Test("Decoding does not mutate CPU or machine state")
    func decodingIsPure() {
        let machine = Machine()
        let before = machine.snapshot()
        _ = decoder.decode(opcode: 0x90, nextByte: forbiddenReader())
        _ = decoder.decode(opcode: 0xF4, nextByte: forbiddenReader())
        _ = decoder.decode(opcode: 0xAB, nextByte: forbiddenReader())
        let after = machine.snapshot()
        #expect(after.cpu.ip == before.cpu.ip)
        #expect(after.cpu.lastFetchedOpcode == before.cpu.lastFetchedOpcode)
        #expect(after.cycleCount == before.cycleCount)
    }

    @Test("Decoding the same opcode twice yields the same instruction")
    func decodingIsDeterministic() {
        for opcode in UInt8.min...UInt8.max {
            let first = decoder.decode(opcode: opcode, nextByte: forbiddenReader())
            let second = decoder.decode(opcode: opcode, nextByte: forbiddenReader())
            #expect(first == second)
        }
    }
}
