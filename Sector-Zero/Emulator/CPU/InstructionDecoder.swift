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
            guard let op = ALUBinaryOp(aluSelector: opcode >> 3) else { return .unknown(opcode) }
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
            let op = ALUBinaryOp(aluSelector: modRM.reg) // nil for ADC (/2), SBB (/3) — M24
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
        case 0x84, 0x85:
            // TEST r/m, reg — AND that writes nothing (writesResult == false),
            // so the shared ALU path charges 3 (reg) / 9+EA (mem), no write.
            let modRM = modRMDecoder.decode(modRMByte: nextByte(), registers: registers, nextByte: nextByte)
            if opcode & 0b01 != 0 {
                return .aluRegisterToRM16(op: .test, source: Register16(rawValue: modRM.reg)!, destination: modRM.operand, eaClocks: modRM.eaClocks)
            }
            return .aluRegisterToRM8(op: .test, source: Register8(rawValue: modRM.reg)!, destination: modRM.operand, eaClocks: modRM.eaClocks)
        case 0xA8:
            // TEST AL, imm8 — accumulator/register destination (4 clocks).
            return .aluImmediateToRM8(op: .test, destination: .register(0), immediate: nextByte(), eaClocks: 0)
        case 0xA9:
            let low = nextByte()
            let high = nextByte()
            return .aluImmediateToRM16(op: .test, destination: .register(0), immediate: UInt16(high) << 8 | UInt16(low), eaClocks: 0)
        case let accumulator where accumulator & 0b11000110 == 0b00000100:
            // Accumulator-immediate ALU shortcuts: <op> AL,imm8 / <op> AX,imm16,
            // op in bits 5–3. AL/AX (encoding 0) is the destination, so the
            // immediate-ALU execution charges the 4-clock register path. The
            // immediate is consumed even for the unimplemented ADC/SBB so IP
            // stays aligned (as with the 80/81/83 group).
            let isWord = accumulator & 0b01 != 0
            let immediate: UInt16
            if isWord {
                let low = nextByte()
                let high = nextByte()
                immediate = UInt16(high) << 8 | UInt16(low)
            } else {
                immediate = UInt16(nextByte())
            }
            guard let op = ALUBinaryOp(aluSelector: accumulator >> 3) else { return .unknown(accumulator) }
            return isWord
                ? .aluImmediateToRM16(op: op, destination: .register(0), immediate: immediate, eaClocks: 0)
                : .aluImmediateToRM8(op: op, destination: .register(0), immediate: UInt8(truncatingIfNeeded: immediate), eaClocks: 0)
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
        case 0x86, 0x87:
            // XCHG r/m ↔ reg: swap the reg operand with r/m; no flags.
            let modRM = modRMDecoder.decode(modRMByte: nextByte(), registers: registers, nextByte: nextByte)
            if opcode & 0b01 != 0 {
                return .exchangeRM16(register: Register16(rawValue: modRM.reg)!, rm: modRM.operand, eaClocks: modRM.eaClocks)
            }
            return .exchangeRM8(register: Register8(rawValue: modRM.reg)!, rm: modRM.operand, eaClocks: modRM.eaClocks)
        case 0x91...0x97:
            // XCHG AX, reg — one-byte form; 0x90 (XCHG AX,AX) is NOP above.
            return .exchangeAXWithRegister(Register16(rawValue: opcode & 0b111)!)
        case 0xA0...0xA3:
            // MOV AL/AX ↔ direct-address moffs16 (DS-relative). Bit 0 = width,
            // bit 1 = direction (0 loads the accumulator, 1 stores it).
            let low = nextByte()
            let high = nextByte()
            return .movMemoryOffset(
                offset: UInt16(high) << 8 | UInt16(low),
                isWord: opcode & 0b01 != 0,
                store: opcode & 0b10 != 0
            )
        case 0xC6, 0xC7:
            // MOV r/m, imm — only the ModR/M reg field /0 is defined. Bytes are
            // consumed before that check so IP stays aligned for other reg values.
            let modRM = modRMDecoder.decode(modRMByte: nextByte(), registers: registers, nextByte: nextByte)
            if opcode & 0b01 != 0 {
                let low = nextByte()
                let high = nextByte()
                guard modRM.reg == 0 else { return .unknown(opcode) }
                return .movImmediateToRM16(destination: modRM.operand, value: UInt16(high) << 8 | UInt16(low), eaClocks: modRM.eaClocks)
            }
            let value = nextByte()
            guard modRM.reg == 0 else { return .unknown(opcode) }
            return .movImmediateToRM8(destination: modRM.operand, value: value, eaClocks: modRM.eaClocks)
        case 0x8C:
            // MOV r/m16, sreg — the ModR/M reg field selects the segment.
            let modRM = modRMDecoder.decode(modRMByte: nextByte(), registers: registers, nextByte: nextByte)
            return .movSegmentToRM(destination: modRM.operand, segment: SegmentRegister(segmentEncoding: modRM.reg), eaClocks: modRM.eaClocks)
        case 0x8E:
            // MOV sreg, r/m16. Writing CS is accepted on the 8086 (later CPUs
            // fault); we match the silicon and let it redirect the fetch.
            let modRM = modRMDecoder.decode(modRMByte: nextByte(), registers: registers, nextByte: nextByte)
            return .movRMToSegment(segment: SegmentRegister(segmentEncoding: modRM.reg), source: modRM.operand, eaClocks: modRM.eaClocks)
        case let sreg where sreg & 0b11100110 == 0b00000110:
            // PUSH/POP sreg: 000-ss-11d, bits 4–3 select ES/CS/SS/DS, bit 0
            // push(0)/pop(1). 0x0F is POP CS — the 8086's real encoding (later
            // CPUs repurpose 0F as the two-byte-opcode escape).
            let segment = SegmentRegister(segmentEncoding: sreg >> 3)
            return sreg & 0b01 == 0 ? .pushSegment(segment) : .popSegment(segment)
        case 0x9C:
            return .pushFlags
        case 0x9D:
            return .popFlags
        case 0x9E:
            return .storeAHIntoStatusFlags
        case 0x9F:
            return .loadStatusFlagsIntoAH
        case 0xF5:
            return .complementCarry
        case 0xF8:
            return .clearFlag(.carry)
        case 0xF9:
            return .setFlag(.carry)
        case 0xFA:
            return .clearFlag(.interruptEnable)
        case 0xFB:
            return .setFlag(.interruptEnable)
        case 0xFC:
            return .clearFlag(.direction)
        case 0xFD:
            return .setFlag(.direction)
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
