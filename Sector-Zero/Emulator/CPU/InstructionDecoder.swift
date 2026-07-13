import Foundation

/// Translates fetched opcode bytes into typed `Instruction` values.
///
/// Decoding is pure: it never touches registers, memory, or flags. The
/// `nextByte` reader is the boundary through which operand-bearing
/// instructions (immediates, ModR/M, displacements) will pull additional
/// bytes from the code stream — immediates and ModR/M displacements. The
/// register file is read (never written) to resolve effective addresses.
struct InstructionDecoder {
    private let modRMDecoder = ModRMDecoder()

    func decode(opcode: UInt8, registers: RegisterFile, nextByte: () -> UInt8) -> Instruction {
        switch opcode {
        case 0x00...0x03, 0x08...0x0B, 0x20...0x23, 0x28...0x2B, 0x30...0x33, 0x38...0x3B:
            // ALU r/m ↔ reg blocks, same width/direction bit layout as MOV
            // below; bits 5–3 of the opcode name the operation.
            let op: ALUBinaryOp
            switch opcode >> 3 {
            case 0b00000: op = .add
            case 0b00001: op = .or
            case 0b00100: op = .and
            case 0b00101: op = .sub
            case 0b00110: op = .xor
            default:      op = .cmp
            }
            let modRM = modRMDecoder.decode(modRMByte: nextByte(), registers: registers, nextByte: nextByte)
            let isWord = opcode & 0b01 != 0
            let regIsDestination = opcode & 0b10 != 0
            switch (isWord, regIsDestination) {
            case (false, false):
                return .aluRegisterToRM8(
                    op: op,
                    source: Register8(rawValue: modRM.reg)!,
                    destination: modRM.operand,
                    eaClocks: modRM.eaClocks
                )
            case (true, false):
                return .aluRegisterToRM16(
                    op: op,
                    source: Register16(rawValue: modRM.reg)!,
                    destination: modRM.operand,
                    eaClocks: modRM.eaClocks
                )
            case (false, true):
                return .aluRMToRegister8(
                    op: op,
                    destination: Register8(rawValue: modRM.reg)!,
                    source: modRM.operand,
                    eaClocks: modRM.eaClocks
                )
            case (true, true):
                return .aluRMToRegister16(
                    op: op,
                    destination: Register16(rawValue: modRM.reg)!,
                    source: modRM.operand,
                    eaClocks: modRM.eaClocks
                )
            }
        case 0x80, 0x81, 0x83:
            // Immediate ALU group: the ModR/M reg field selects the operation
            // (/0 ADD, /5 SUB, /7 CMP). 0x80 takes imm8, 0x81 imm16, 0x83 a
            // sign-extended imm8 into a 16-bit destination. The immediate is
            // consumed even for the group's unimplemented operations so IP
            // still lands on the next instruction (no-op-and-advance).
            let modRM = modRMDecoder.decode(modRMByte: nextByte(), registers: registers, nextByte: nextByte)
            let op: ALUBinaryOp?
            switch modRM.reg {
            case 0b000: op = .add
            case 0b001: op = .or
            case 0b100: op = .and
            case 0b101: op = .sub
            case 0b110: op = .xor
            case 0b111: op = .cmp
            default:    op = nil // ADC (/2), SBB (/3) — M24
            }
            if opcode == 0x80 {
                let immediate = nextByte()
                guard let op else { return .unknown(opcode) }
                return .aluImmediateToRM8(op: op, destination: modRM.operand, immediate: immediate, eaClocks: modRM.eaClocks)
            }
            let immediate: UInt16
            if opcode == 0x81 {
                let low = nextByte()
                let high = nextByte()
                immediate = UInt16(high) << 8 | UInt16(low)
            } else {
                immediate = UInt16(bitPattern: Int16(Int8(bitPattern: nextByte())))
            }
            guard let op else { return .unknown(opcode) }
            return .aluImmediateToRM16(op: op, destination: modRM.operand, immediate: immediate, eaClocks: modRM.eaClocks)
        case 0x40...0x47:
            return .incRegister16(Register16(rawValue: opcode & 0b111)!)
        case 0x48...0x4F:
            return .decRegister16(Register16(rawValue: opcode & 0b111)!)
        case 0x50...0x57:
            return .pushRegister16(Register16(rawValue: opcode & 0b111)!)
        case 0x58...0x5F:
            return .popRegister16(Register16(rawValue: opcode & 0b111)!)
        case 0x70...0x7F:
            // Jcc short: signed disp8 relative to the next instruction.
            return .jumpConditional(
                condition: JumpCondition(encoding: opcode & 0xF),
                displacement: Int8(bitPattern: nextByte())
            )
        case 0xE0...0xE2:
            // LOOPNE / LOOPE / LOOP, all with a signed disp8.
            let condition: LoopCondition = switch opcode {
            case 0xE0: .whileNotZero
            case 0xE1: .whileZero
            default:   .unconditional
            }
            return .loop(condition: condition, displacement: Int8(bitPattern: nextByte()))
        case 0xE3:
            return .jumpIfCXZero(displacement: Int8(bitPattern: nextByte()))
        case 0xC3:
            return .returnNear
        case 0xE8:
            // CALL near-relative: signed disp16, little-endian in the stream.
            let low = nextByte()
            let high = nextByte()
            return .callNearRelative(displacement: Int16(bitPattern: UInt16(high) << 8 | UInt16(low)))
        case 0xE9:
            // JMP near-relative: signed disp16, little-endian.
            let low = nextByte()
            let high = nextByte()
            return .jumpNear(displacement: Int16(bitPattern: UInt16(high) << 8 | UInt16(low)))
        case 0xEA:
            // JMP far (direct intersegment): little-endian offset then segment.
            let offsetLow = nextByte()
            let offsetHigh = nextByte()
            let segmentLow = nextByte()
            let segmentHigh = nextByte()
            return .jumpFar(
                offset: UInt16(offsetHigh) << 8 | UInt16(offsetLow),
                segment: UInt16(segmentHigh) << 8 | UInt16(segmentLow)
            )
        case 0xEB:
            return .jumpShort(displacement: Int8(bitPattern: nextByte()))
        case 0x88, 0x89, 0x8A, 0x8B:
            // MOV r/m ↔ reg. Bit 0 selects width, bit 1 the direction
            // (0: reg is source, 1: reg is destination).
            let modRM = modRMDecoder.decode(modRMByte: nextByte(), registers: registers, nextByte: nextByte)
            let isWord = opcode & 0b01 != 0
            let regIsDestination = opcode & 0b10 != 0
            switch (isWord, regIsDestination) {
            case (false, false):
                return .movRegisterToRM8(
                    source: Register8(rawValue: modRM.reg)!,
                    destination: modRM.operand,
                    eaClocks: modRM.eaClocks
                )
            case (true, false):
                return .movRegisterToRM16(
                    source: Register16(rawValue: modRM.reg)!,
                    destination: modRM.operand,
                    eaClocks: modRM.eaClocks
                )
            case (false, true):
                return .movRMToRegister8(
                    destination: Register8(rawValue: modRM.reg)!,
                    source: modRM.operand,
                    eaClocks: modRM.eaClocks
                )
            case (true, true):
                return .movRMToRegister16(
                    destination: Register16(rawValue: modRM.reg)!,
                    source: modRM.operand,
                    eaClocks: modRM.eaClocks
                )
            }
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
