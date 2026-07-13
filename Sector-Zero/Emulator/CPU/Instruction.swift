import Foundation

/// F3 selects the equal gate and F2 the not-equal gate for comparison strings;
/// either prefix repeats movement strings unconditionally. Multiple repeat
/// prefixes are legal and the last one before the opcode wins.
enum RepeatPrefix: Equatable, Sendable {
    case whileEqual
    case whileNotEqual

    init?(opcode: UInt8) {
        switch opcode {
        case 0xF3: self = .whileEqual
        case 0xF2: self = .whileNotEqual
        default: return nil
        }
    }
}

/// IN/OUT select either a zero-extended encoded byte or the full DX register.
enum IOPortSource: Equatable, Sendable {
    case immediate(UInt8)
    case dx
}

struct RepeatExecutionResult: Equatable, Sendable {
    let cycles: Int
    let interrupted: Bool
}

/// A decoded 8086 instruction, independent of how its bytes were fetched.
///
/// Encodings outside the supported 8086 matrix decode to `.unknown` carrying
/// their primary byte; execution turns that value into an emulator diagnostic.
enum Instruction: Equatable {
    case nop
    case hlt
    case movImmediateToRegister8(Register8, UInt8)
    case movImmediateToRegister16(Register16, UInt16)
    case movRegisterToRM8(source: Register8, destination: ModRMOperand, eaClocks: Int)
    case movRegisterToRM16(source: Register16, destination: ModRMOperand, eaClocks: Int)
    case movRMToRegister8(destination: Register8, source: ModRMOperand, eaClocks: Int)
    case movRMToRegister16(destination: Register16, source: ModRMOperand, eaClocks: Int)
    case movImmediateToRM8(destination: ModRMOperand, value: UInt8, eaClocks: Int)
    case movImmediateToRM16(destination: ModRMOperand, value: UInt16, eaClocks: Int)
    /// MOV between AL/AX and a direct-address offset (DS-relative), 0xA0–0xA3.
    case movMemoryOffset(offset: UInt16, isWord: Bool, store: Bool)
    case moveString(isWord: Bool)
    case loadString(isWord: Bool)
    case storeString(isWord: Bool)
    case compareString(isWord: Bool)
    case scanString(isWord: Bool)
    case exchangeRM8(register: Register8, rm: ModRMOperand, eaClocks: Int)
    case exchangeRM16(register: Register16, rm: ModRMOperand, eaClocks: Int)
    case exchangeAXWithRegister(Register16)
    case movSegmentToRM(destination: ModRMOperand, segment: SegmentRegister, eaClocks: Int)
    case movRMToSegment(segment: SegmentRegister, source: ModRMOperand, eaClocks: Int)
    case loadEffectiveAddress(destination: Register16, offset: UInt16, eaClocks: Int)
    case loadFarPointer(destination: Register16, segment: SegmentRegister, source: ModRMOperand, eaClocks: Int)
    case pushSegment(SegmentRegister)
    case popSegment(SegmentRegister)
    case pushFlags
    case popFlags
    case loadStatusFlagsIntoAH
    case storeAHIntoStatusFlags
    case clearFlag(CPUFlag)
    case setFlag(CPUFlag)
    case complementCarry
    case decimalAdjustAfterAddition
    case decimalAdjustAfterSubtraction
    case asciiAdjustAfterAddition
    case asciiAdjustAfterSubtraction
    case asciiAdjustAfterMultiply(base: UInt8)
    case asciiAdjustBeforeDivision(base: UInt8)
    case convertByteToWord
    case convertWordToDoubleword
    case translateByte
    case input(port: IOPortSource, isWord: Bool)
    case output(port: IOPortSource, isWord: Bool)
    case waitForCoprocessor
    case coprocessorEscape(opcode: UInt8, modRM: UInt8, operand: ModRMOperand, eaClocks: Int)
    case shiftRotate8(operation: ShiftRotateOperation, destination: ModRMOperand, count: ShiftCount, eaClocks: Int)
    case shiftRotate16(operation: ShiftRotateOperation, destination: ModRMOperand, count: ShiftCount, eaClocks: Int)
    case testImmediateRM8(destination: ModRMOperand, immediate: UInt8, eaClocks: Int)
    case testImmediateRM16(destination: ModRMOperand, immediate: UInt16, eaClocks: Int)
    case unary8(operation: UnaryOperation, operand: ModRMOperand, eaClocks: Int)
    case unary16(operation: UnaryOperation, operand: ModRMOperand, eaClocks: Int)
    case aluRegisterToRM8(op: ALUBinaryOp, source: Register8, destination: ModRMOperand, eaClocks: Int)
    case aluRegisterToRM16(op: ALUBinaryOp, source: Register16, destination: ModRMOperand, eaClocks: Int)
    case aluRMToRegister8(op: ALUBinaryOp, destination: Register8, source: ModRMOperand, eaClocks: Int)
    case aluRMToRegister16(op: ALUBinaryOp, destination: Register16, source: ModRMOperand, eaClocks: Int)
    case aluImmediateToRM8(op: ALUBinaryOp, destination: ModRMOperand, immediate: UInt8, eaClocks: Int)
    case aluImmediateToRM16(op: ALUBinaryOp, destination: ModRMOperand, immediate: UInt16, eaClocks: Int)
    case incRegister16(Register16)
    case decRegister16(Register16)
    case incRM8(destination: ModRMOperand, eaClocks: Int)
    case decRM8(destination: ModRMOperand, eaClocks: Int)
    case incRM16(destination: ModRMOperand, eaClocks: Int)
    case decRM16(destination: ModRMOperand, eaClocks: Int)
    case pushRegister16(Register16)
    case popRegister16(Register16)
    case pushRM16(source: ModRMOperand, eaClocks: Int)
    case popRM16(destination: ModRMOperand, eaClocks: Int)
    case callNearRelative(displacement: Int16)
    case callNearIndirect(source: ModRMOperand, eaClocks: Int)
    case callFar(offset: UInt16, segment: UInt16)
    case callFarIndirect(source: ModRMOperand, eaClocks: Int)
    case returnNear
    case returnNearAdjust(UInt16)
    case returnFar
    case returnFarAdjust(UInt16)
    case breakpointInterrupt
    case softwareInterrupt(UInt8)
    case interruptOnOverflow
    case interruptReturn
    case jumpConditional(condition: JumpCondition, displacement: Int8)
    case jumpShort(displacement: Int8)
    case jumpNear(displacement: Int16)
    case jumpNearIndirect(source: ModRMOperand, eaClocks: Int)
    case jumpFar(offset: UInt16, segment: UInt16)
    case jumpFarIndirect(source: ModRMOperand, eaClocks: Int)
    case loop(condition: LoopCondition, displacement: Int8)
    case jumpIfCXZero(displacement: Int8)
    case unknown(UInt8)
}

extension Instruction {
    /// LOCK is accepted only for instructions that write a memory destination
    /// derived from the value read from that same destination.
    var isLockableMemoryReadModifyWrite: Bool {
        switch self {
        case .exchangeRM8(_, .memory, _), .exchangeRM16(_, .memory, _),
             .incRM8(.memory, _), .decRM8(.memory, _),
             .incRM16(.memory, _), .decRM16(.memory, _),
             .shiftRotate8(_, .memory, _, _), .shiftRotate16(_, .memory, _, _):
            return true
        case .unary8(let operation, .memory, _), .unary16(let operation, .memory, _):
            return operation == .not || operation == .negate
        case .aluRegisterToRM8(let operation, _, .memory, _),
             .aluRegisterToRM16(let operation, _, .memory, _),
             .aluImmediateToRM8(let operation, .memory, _, _),
             .aluImmediateToRM16(let operation, .memory, _, _):
            return operation.writesResult
        default:
            return false
        }
    }
}

/// The defined non-immediate selectors in the 8086 F6/F7 unary group. TEST
/// (/0) has a separate instruction shape because it also consumes an immediate;
/// /1 is intentionally absent because Intel leaves it undefined.
enum UnaryOperation: UInt8, Equatable, Sendable {
    case not = 2
    case negate = 3
    case multiplyUnsigned = 4
    case multiplySigned = 5
    case divideUnsigned = 6
    case divideSigned = 7
}

/// The seven defined selectors in the 8086 D0–D3 shift/rotate group. Selector
/// /6 is intentionally absent because it is not a documented 8086 operation.
enum ShiftRotateOperation: UInt8, Equatable, Sendable {
    case rotateLeft = 0
    case rotateRight = 1
    case rotateCarryLeft = 2
    case rotateCarryRight = 3
    case shiftLeft = 4
    case shiftRight = 5
    case shiftArithmeticRight = 7

    init?(groupSelector: UInt8) {
        self.init(rawValue: groupSelector & 0b111)
    }

    var isShift: Bool {
        switch self {
        case .shiftLeft, .shiftRight, .shiftArithmeticRight: true
        default: false
        }
    }
}

/// D0/D1 encode an implicit count of one; D2/D3 read the full, unmasked CL
/// value on the original 8086.
enum ShiftCount: Equatable, Sendable {
    case one
    case cl
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
    case adc
    case sbb
    case sub
    case cmp
    case and
    case or
    case xor
    case test

    /// Whether the operation writes its result back to the destination. CMP
    /// and TEST only set flags — they are SUB and AND with the write suppressed.
    var writesResult: Bool {
        self != .cmp && self != .test
    }

    /// Maps the 3-bit operation selector shared by the ALU opcode encodings:
    /// bits 5–3 of the r/m↔reg and accumulator-immediate opcodes, and the
    /// ModR/M reg field of the 80/81/83 immediate group. TEST has its own
    /// opcodes rather than one of these selectors.
    init?(aluSelector selector: UInt8) {
        switch selector & 0b111 {
        case 0b000: self = .add
        case 0b001: self = .or
        case 0b010: self = .adc
        case 0b011: self = .sbb
        case 0b100: self = .and
        case 0b101: self = .sub
        case 0b110: self = .xor
        case 0b111: self = .cmp
        default: return nil
        }
    }
}
