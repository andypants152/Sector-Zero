import Foundation

/// A segment register name, used to record which segment a memory operand
/// addresses by default (overridable by segment prefixes, a later milestone).
enum SegmentRegister: Equatable, Sendable {
    case es, cs, ss, ds

    /// The 2-bit segment encoding used by MOV sreg (8C/8E reg field) and the
    /// PUSH/POP sreg opcodes: 0=ES, 1=CS, 2=SS, 3=DS. The 8086 ignores bit 2
    /// of the ModR/M reg field for these, so only the low two bits matter.
    init(segmentEncoding reg: UInt8) {
        switch reg & 0b11 {
        case 0: self = .es
        case 1: self = .cs
        case 2: self = .ss
        default: self = .ds
        }
    }

    /// The segment named by a segment-override prefix byte, or nil if the byte
    /// is not one of 0x26 (ES), 0x2E (CS), 0x36 (SS), 0x3E (DS).
    init?(overridePrefix opcode: UInt8) {
        switch opcode {
        case 0x26: self = .es
        case 0x2E: self = .cs
        case 0x36: self = .ss
        case 0x3E: self = .ds
        default: return nil
        }
    }
}

/// A resolved memory operand: a 16-bit offset plus the segment it addresses
/// unless a prefix overrides it. BP-based modes default to SS; all others to DS.
struct EffectiveAddress: Equatable, Sendable {
    let offset: UInt16
    let defaultSegment: SegmentRegister
}

/// The operand selected by a ModR/M byte's mod + r/m fields.
enum ModRMOperand: Equatable, Sendable {
    /// mod=11: the 3-bit register encoding. The consuming instruction decides
    /// whether it names a `Register8` or `Register16` (both share raw values).
    case register(UInt8)
    case memory(EffectiveAddress)
}

/// A fully decoded ModR/M byte.
struct ModRM: Equatable, Sendable {
    /// Addressing form, bits 7–6 (0–3).
    let mod: UInt8
    /// Register operand or opcode extension, bits 5–3 (0–7). Width and meaning
    /// are the consuming instruction's to interpret.
    let reg: UInt8
    /// The r/m-selected operand with any displacement already folded in.
    let operand: ModRMOperand
    /// Documented 8086 effective-address time in clocks (0 for register
    /// operands); instructions add this to their base execution cost.
    let eaClocks: Int
}

/// Decodes ModR/M bytes and computes effective addresses.
///
/// Pure: reads register values to form base+index addresses but mutates
/// nothing. Displacement bytes are pulled through `nextByte` — the same
/// fetch↔decode boundary the instruction decoder uses — so consumed length
/// falls out of how many bytes the caller's stream yields. All effective
/// address arithmetic wraps at 16 bits, matching the 8086.
struct ModRMDecoder {
    func decode(modRMByte: UInt8, registers: RegisterFile, nextByte: () -> UInt8) -> ModRM {
        let mod = modRMByte >> 6
        let reg = (modRMByte >> 3) & 0b111
        let rm = modRMByte & 0b111

        if mod == 0b11 {
            return ModRM(mod: mod, reg: reg, operand: .register(rm), eaClocks: 0)
        }

        // mod=00 r/m=110 is the direct-address special case: no base or index,
        // just a 16-bit address (DS-relative). BP+0 is unreachable in mod=00,
        // which is why BP-relative forms require mod=01/10.
        if mod == 0b00 && rm == 0b110 {
            let low = nextByte()
            let high = nextByte()
            let address = UInt16(high) << 8 | UInt16(low)
            let effectiveAddress = EffectiveAddress(offset: address, defaultSegment: .ds)
            return ModRM(mod: mod, reg: reg, operand: .memory(effectiveAddress), eaClocks: 6)
        }

        let base = baseAndIndex(rm: rm, registers: registers)
        let displacement: UInt16
        switch mod {
        case 0b01:
            // disp8 is sign-extended to 16 bits.
            displacement = UInt16(bitPattern: Int16(Int8(bitPattern: nextByte())))
        case 0b10:
            let low = nextByte()
            let high = nextByte()
            displacement = UInt16(high) << 8 | UInt16(low)
        default:
            displacement = 0
        }

        let effectiveAddress = EffectiveAddress(
            offset: base.offset &+ displacement,
            defaultSegment: base.defaultSegment
        )
        return ModRM(
            mod: mod,
            reg: reg,
            operand: .memory(effectiveAddress),
            eaClocks: effectiveAddressClocks(mod: mod, rm: rm)
        )
    }

    /// Documented 8086 effective-address times: base or index only 5; direct
    /// address 6; base+index 7 (BP+DI, BX+SI) or 8 (BP+SI, BX+DI);
    /// displacement+base-or-index 9; displacement+base+index 11 or 12.
    private func effectiveAddressClocks(mod: UInt8, rm: UInt8) -> Int {
        let hasDisplacement = mod != 0b00
        switch rm {
        case 0b000, 0b011: return hasDisplacement ? 11 : 7  // BX+SI, BP+DI
        case 0b001, 0b010: return hasDisplacement ? 12 : 8  // BX+DI, BP+SI
        default:           return hasDisplacement ? 9 : 5   // single base or index
        }
    }

    /// The base+index sum and default segment for a memory-form r/m encoding.
    private func baseAndIndex(rm: UInt8, registers: RegisterFile) -> (offset: UInt16, defaultSegment: SegmentRegister) {
        switch rm {
        case 0b000: return (registers[.bx] &+ registers[.si], .ds)
        case 0b001: return (registers[.bx] &+ registers[.di], .ds)
        case 0b010: return (registers[.bp] &+ registers[.si], .ss)
        case 0b011: return (registers[.bp] &+ registers[.di], .ss)
        case 0b100: return (registers[.si], .ds)
        case 0b101: return (registers[.di], .ds)
        case 0b110: return (registers[.bp], .ss) // mod=01/10 only; mod=00 is direct address
        default:    return (registers[.bx], .ds)
        }
    }
}
