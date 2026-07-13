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
    case movImmediateToRegister8(Register8, UInt8)
    case movImmediateToRegister16(Register16, UInt16)
    case movRegisterToRM8(source: Register8, destination: ModRMOperand, eaClocks: Int)
    case movRegisterToRM16(source: Register16, destination: ModRMOperand, eaClocks: Int)
    case movRMToRegister8(destination: Register8, source: ModRMOperand, eaClocks: Int)
    case movRMToRegister16(destination: Register16, source: ModRMOperand, eaClocks: Int)
    case aluRegisterToRM8(op: ALUBinaryOp, source: Register8, destination: ModRMOperand, eaClocks: Int)
    case aluRegisterToRM16(op: ALUBinaryOp, source: Register16, destination: ModRMOperand, eaClocks: Int)
    case aluRMToRegister8(op: ALUBinaryOp, destination: Register8, source: ModRMOperand, eaClocks: Int)
    case aluRMToRegister16(op: ALUBinaryOp, destination: Register16, source: ModRMOperand, eaClocks: Int)
    case aluImmediateToRM8(op: ALUBinaryOp, destination: ModRMOperand, immediate: UInt8, eaClocks: Int)
    case aluImmediateToRM16(op: ALUBinaryOp, destination: ModRMOperand, immediate: UInt16, eaClocks: Int)
    case incRegister16(Register16)
    case decRegister16(Register16)
    case pushRegister16(Register16)
    case popRegister16(Register16)
    case callNearRelative(displacement: Int16)
    case returnNear
    case jumpConditional(condition: JumpCondition, displacement: Int8)
    case jumpShort(displacement: Int8)
    case jumpNear(displacement: Int16)
    case jumpFar(offset: UInt16, segment: UInt16)
    case loop(condition: LoopCondition, displacement: Int8)
    case jumpIfCXZero(displacement: Int8)
    case unknown(UInt8)
}

/// A Jcc condition, from the low nibble of opcodes 0x70–0x7F. The low bit
/// inverts the base predicate (JO/JNO, JB/JNB, …).
struct JumpCondition: Equatable, Sendable {
    let encoding: UInt8

    init(encoding: UInt8) {
        self.encoding = encoding & 0xF
    }

    /// The documented 8086 predicates: JO=OF, JB=CF, JZ=ZF, JBE=CF∨ZF,
    /// JS=SF, JP=PF, JL=SF≠OF, JLE=ZF∨(SF≠OF); odd encodings negate.
    func isSatisfied(by flags: CPUFlags) -> Bool {
        let base: Bool
        switch encoding >> 1 {
        case 0: base = flags[.overflow]
        case 1: base = flags[.carry]
        case 2: base = flags[.zero]
        case 3: base = flags[.carry] || flags[.zero]
        case 4: base = flags[.sign]
        case 5: base = flags[.parity]
        case 6: base = flags[.sign] != flags[.overflow]
        default: base = flags[.zero] || (flags[.sign] != flags[.overflow])
        }
        return encoding & 1 == 0 ? base : !base
    }
}

/// The LOOP family's gate beyond CX ≠ 0: LOOPE (E1) also requires ZF set,
/// LOOPNE (E0) ZF clear. Taken/not-taken clock costs differ per variant.
enum LoopCondition: Equatable, Sendable {
    case unconditional
    case whileZero
    case whileNotZero

    func isSatisfied(by flags: CPUFlags) -> Bool {
        switch self {
        case .unconditional: true
        case .whileZero: flags[.zero]
        case .whileNotZero: !flags[.zero]
        }
    }

    var takenClocks: Int {
        switch self {
        case .unconditional: 17
        case .whileZero: 18
        case .whileNotZero: 19
        }
    }

    var notTakenClocks: Int {
        switch self {
        case .unconditional: 5
        case .whileZero: 6
        case .whileNotZero: 5
        }
    }
}

/// A binary ALU operation decoded from an r/m↔reg opcode block. CMP computes
/// like SUB but discards its result, updating only flags.
enum ALUBinaryOp: Equatable, Sendable {
    case add
    case sub
    case cmp

    /// Whether the operation writes its result back to the destination.
    var writesResult: Bool {
        self != .cmp
    }
}
