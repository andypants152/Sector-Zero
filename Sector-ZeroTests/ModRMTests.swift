import Testing
@testable import Sector_Zero

/// Milestone 8 — ModR/M decoding + effective address calculation.
///
/// The ModR/M byte is mmrrrqqq: `mod` (bits 7–6) selects the addressing form,
/// `reg` (5–3) names a register operand or opcode extension, `r/m` (2–0)
/// selects the other operand. mod=11 is register-direct; mod=00/01/10 are
/// memory forms with 0-, 8- (sign-extended), or 16-bit displacement. The
/// special case mod=00 r/m=110 is a direct 16-bit address. BP-based modes
/// default to the SS segment; everything else defaults to DS.
struct ModRMTests {
    private let decoder = ModRMDecoder()

    /// Registers seeded with distinct values so each EA term is identifiable.
    private var registers: RegisterFile {
        var file = RegisterFile()
        file[.bx] = 0x1000
        file[.bp] = 0x2000
        file[.si] = 0x0300
        file[.di] = 0x0400
        return file
    }

    private func decode(_ bytes: [UInt8]) -> (modRM: ModRM, consumed: Int) {
        var stream = bytes
        let modRM = decoder.decode(modRMByte: stream.removeFirst(), registers: registers) {
            stream.removeFirst()
        }
        return (modRM, bytes.count - stream.count)
    }

    private func modRMByte(mod: UInt8, reg: UInt8, rm: UInt8) -> UInt8 {
        mod << 6 | reg << 3 | rm
    }

    // MARK: Field extraction

    @Test("mod, reg and r/m fields are extracted from the byte")
    func fieldExtraction() {
        let (modRM, _) = decode([0b11_010_001])
        #expect(modRM.mod == 0b11)
        #expect(modRM.reg == 0b010)
    }

    // MARK: mod=11 — register direct

    @Test("mod=11 resolves to a register operand for every r/m", arguments: UInt8(0)...7)
    func registerDirect(rm: UInt8) {
        let (modRM, consumed) = decode([modRMByte(mod: 0b11, reg: 0, rm: rm)])
        #expect(modRM.operand == .register(rm))
        #expect(consumed == 1)
    }

    // MARK: mod=00 — no displacement

    @Test("mod=00 memory forms compute base+index with no displacement", arguments: [
        // (r/m, expected offset, expected default segment)
        (UInt8(0), UInt16(0x1300), SegmentRegister.ds), // BX+SI
        (1, 0x1400, .ds),                               // BX+DI
        (2, 0x2300, .ss),                               // BP+SI
        (3, 0x2400, .ss),                               // BP+DI
        (4, 0x0300, .ds),                               // SI
        (5, 0x0400, .ds),                               // DI
        (7, 0x1000, .ds),                               // BX
    ])
    func noDisplacement(rm: UInt8, offset: UInt16, segment: SegmentRegister) {
        let (modRM, consumed) = decode([modRMByte(mod: 0b00, reg: 0, rm: rm)])
        #expect(modRM.operand == .memory(EffectiveAddress(offset: offset, defaultSegment: segment)))
        #expect(consumed == 1)
    }

    @Test("mod=00 r/m=110 is the direct-address special case (disp16, DS)")
    func directAddress() {
        let (modRM, consumed) = decode([modRMByte(mod: 0b00, reg: 0, rm: 6), 0xCD, 0xAB])
        #expect(modRM.operand == .memory(EffectiveAddress(offset: 0xABCD, defaultSegment: .ds)))
        #expect(consumed == 3)
    }

    // MARK: mod=01 — 8-bit displacement, sign-extended

    @Test("mod=01 adds a sign-extended positive disp8")
    func disp8Positive() {
        let (modRM, consumed) = decode([modRMByte(mod: 0b01, reg: 0, rm: 0), 0x12])
        #expect(modRM.operand == .memory(EffectiveAddress(offset: 0x1312, defaultSegment: .ds)))
        #expect(consumed == 2)
    }

    @Test("mod=01 sign-extends a negative disp8")
    func disp8Negative() {
        // BX+SI = 0x1300; disp8 0xFE = -2 → 0x12FE.
        let (modRM, _) = decode([modRMByte(mod: 0b01, reg: 0, rm: 0), 0xFE])
        #expect(modRM.operand == .memory(EffectiveAddress(offset: 0x12FE, defaultSegment: .ds)))
    }

    @Test("mod=01 r/m=110 is BP+disp8 defaulting to SS (not direct address)")
    func bpDisp8() {
        let (modRM, consumed) = decode([modRMByte(mod: 0b01, reg: 0, rm: 6), 0x10])
        #expect(modRM.operand == .memory(EffectiveAddress(offset: 0x2010, defaultSegment: .ss)))
        #expect(consumed == 2)
    }

    // MARK: mod=10 — 16-bit displacement

    @Test("mod=10 adds a little-endian disp16 for every memory r/m", arguments: [
        (UInt8(0), UInt16(0x1300), SegmentRegister.ds),
        (1, 0x1400, .ds),
        (2, 0x2300, .ss),
        (3, 0x2400, .ss),
        (4, 0x0300, .ds),
        (5, 0x0400, .ds),
        (6, 0x2000, .ss), // BP+disp16, SS default
        (7, 0x1000, .ds),
    ])
    func disp16(rm: UInt8, base: UInt16, segment: SegmentRegister) {
        let (modRM, consumed) = decode([modRMByte(mod: 0b10, reg: 0, rm: rm), 0x34, 0x12])
        let expected = base &+ 0x1234
        #expect(modRM.operand == .memory(EffectiveAddress(offset: expected, defaultSegment: segment)))
        #expect(consumed == 3)
    }

    // MARK: wraparound

    @Test("Effective address arithmetic wraps at 16 bits")
    func effectiveAddressWraps() {
        var file = RegisterFile()
        file[.bx] = 0xFFFF
        file[.si] = 0x0002
        var stream: [UInt8] = [modRMByte(mod: 0b00, reg: 0, rm: 0)]
        let modRM = decoder.decode(modRMByte: stream.removeFirst(), registers: file) {
            stream.removeFirst()
        }
        #expect(modRM.operand == .memory(EffectiveAddress(offset: 0x0001, defaultSegment: .ds)))
    }

    @Test("Decoding is pure — the register file is not mutated")
    func decodingIsPure() {
        let before = registers
        var file = before
        var stream: [UInt8] = [modRMByte(mod: 0b10, reg: 0b111, rm: 0b010), 0x34, 0x12]
        _ = decoder.decode(modRMByte: stream.removeFirst(), registers: file) {
            stream.removeFirst()
        }
        #expect(file == before)
    }
}
