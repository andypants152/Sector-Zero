import Foundation

/// The six flags an arithmetic operation produces, decoupled from the FLAGS
/// register so the ALU stays pure and independently testable.
struct ArithmeticFlags: Equatable, Sendable {
    let carry: Bool
    let parity: Bool
    let auxiliaryCarry: Bool
    let zero: Bool
    let sign: Bool
    let overflow: Bool
}

/// Shift/rotate flags are optional because count zero changes no flags,
/// rotates do not touch SF/ZF/PF, and OF is undefined for multibit operations.
/// AF is deliberately absent and therefore preserved by the CPU.
struct ShiftRotateFlags: Equatable, Sendable {
    let carry: Bool?
    let parity: Bool?
    let zero: Bool?
    let sign: Bool?
    let overflow: Bool?
}

struct ShiftRotateResult<Value>: Equatable, Sendable
where Value: FixedWidthInteger & UnsignedInteger & Sendable {
    let result: Value
    let flags: ShiftRotateFlags
}

/// Pure 8086 arithmetic with authentic flag semantics. Flag rules:
/// CF = carry out of the top bit; AF = carry out of bit 3; ZF/SF from the
/// result; PF = even parity of the low byte only (both widths); OF = signed
/// overflow, i.e. both operands share a sign the result doesn't.
enum ALU {
    static func add8(_ a: UInt8, _ b: UInt8) -> (result: UInt8, flags: ArithmeticFlags) {
        addWithCarry8(a, b, carryIn: false)
    }

    static func addWithCarry8(
        _ a: UInt8,
        _ b: UInt8,
        carryIn: Bool
    ) -> (result: UInt8, flags: ArithmeticFlags) {
        let carry = carryIn ? UInt16(1) : 0
        let wide = UInt16(a) + UInt16(b) + carry
        let result = UInt8(truncatingIfNeeded: wide)
        let flags = ArithmeticFlags(
            carry: wide > 0xFF,
            parity: hasEvenParity(result),
            auxiliaryCarry: UInt16(a & 0xF) + UInt16(b & 0xF) + carry > 0xF,
            zero: result == 0,
            sign: result & 0x80 != 0,
            overflow: (a ^ result) & (b ^ result) & 0x80 != 0
        )
        return (result, flags)
    }

    static func add16(_ a: UInt16, _ b: UInt16) -> (result: UInt16, flags: ArithmeticFlags) {
        addWithCarry16(a, b, carryIn: false)
    }

    static func addWithCarry16(
        _ a: UInt16,
        _ b: UInt16,
        carryIn: Bool
    ) -> (result: UInt16, flags: ArithmeticFlags) {
        let carry = carryIn ? UInt32(1) : 0
        let wide = UInt32(a) + UInt32(b) + carry
        let result = UInt16(truncatingIfNeeded: wide)
        let flags = ArithmeticFlags(
            carry: wide > 0xFFFF,
            parity: hasEvenParity(UInt8(truncatingIfNeeded: result)),
            auxiliaryCarry: UInt32(a & 0xF) + UInt32(b & 0xF) + carry > 0xF,
            zero: result == 0,
            sign: result & 0x8000 != 0,
            overflow: (a ^ result) & (b ^ result) & 0x8000 != 0
        )
        return (result, flags)
    }

    /// Subtraction flags: CF = borrow; AF = borrow into bit 3; OF = signed
    /// overflow (operands of differing sign where the result's sign flipped
    /// away from the minuend's).
    static func subtract8(_ a: UInt8, _ b: UInt8) -> (result: UInt8, flags: ArithmeticFlags) {
        subtractWithBorrow8(a, b, borrowIn: false)
    }

    static func subtractWithBorrow8(
        _ a: UInt8,
        _ b: UInt8,
        borrowIn: Bool
    ) -> (result: UInt8, flags: ArithmeticFlags) {
        let borrow = borrowIn ? UInt16(1) : 0
        let subtrahend = UInt16(b) + borrow
        let result = UInt8(truncatingIfNeeded: UInt16(a) &- subtrahend)
        let flags = ArithmeticFlags(
            carry: UInt16(a) < subtrahend,
            parity: hasEvenParity(result),
            auxiliaryCarry: UInt16(a & 0xF) < UInt16(b & 0xF) + borrow,
            zero: result == 0,
            sign: result & 0x80 != 0,
            overflow: (a ^ b) & (a ^ result) & 0x80 != 0
        )
        return (result, flags)
    }

    static func subtract16(_ a: UInt16, _ b: UInt16) -> (result: UInt16, flags: ArithmeticFlags) {
        subtractWithBorrow16(a, b, borrowIn: false)
    }

    static func subtractWithBorrow16(
        _ a: UInt16,
        _ b: UInt16,
        borrowIn: Bool
    ) -> (result: UInt16, flags: ArithmeticFlags) {
        let borrow = borrowIn ? UInt32(1) : 0
        let subtrahend = UInt32(b) + borrow
        let result = UInt16(truncatingIfNeeded: UInt32(a) &- subtrahend)
        let flags = ArithmeticFlags(
            carry: UInt32(a) < subtrahend,
            parity: hasEvenParity(UInt8(truncatingIfNeeded: result)),
            auxiliaryCarry: UInt32(a & 0xF) < UInt32(b & 0xF) + borrow,
            zero: result == 0,
            sign: result & 0x8000 != 0,
            overflow: (a ^ b) & (a ^ result) & 0x8000 != 0
        )
        return (result, flags)
    }

    static func shiftRotate8(
        _ value: UInt8,
        operation: ShiftRotateOperation,
        count: UInt8,
        carryIn: Bool
    ) -> ShiftRotateResult<UInt8> {
        shiftRotate(value, operation: operation, count: count, carryIn: carryIn)
    }

    static func shiftRotate16(
        _ value: UInt16,
        operation: ShiftRotateOperation,
        count: UInt8,
        carryIn: Bool
    ) -> ShiftRotateResult<UInt16> {
        shiftRotate(value, operation: operation, count: count, carryIn: carryIn)
    }

    static func and8(_ a: UInt8, _ b: UInt8) -> (result: UInt8, flags: ArithmeticFlags) {
        let result = a & b
        return (result, logicalFlags8(result))
    }

    static func and16(_ a: UInt16, _ b: UInt16) -> (result: UInt16, flags: ArithmeticFlags) {
        let result = a & b
        return (result, logicalFlags16(result))
    }

    static func or8(_ a: UInt8, _ b: UInt8) -> (result: UInt8, flags: ArithmeticFlags) {
        let result = a | b
        return (result, logicalFlags8(result))
    }

    static func or16(_ a: UInt16, _ b: UInt16) -> (result: UInt16, flags: ArithmeticFlags) {
        let result = a | b
        return (result, logicalFlags16(result))
    }

    static func xor8(_ a: UInt8, _ b: UInt8) -> (result: UInt8, flags: ArithmeticFlags) {
        let result = a ^ b
        return (result, logicalFlags8(result))
    }

    static func xor16(_ a: UInt16, _ b: UInt16) -> (result: UInt16, flags: ArithmeticFlags) {
        let result = a ^ b
        return (result, logicalFlags16(result))
    }

    /// Logical ops clear CF and OF, derive ZF/SF/PF from the result, and leave
    /// AF architecturally undefined on the 8086 — we clear it deterministically.
    private static func logicalFlags8(_ result: UInt8) -> ArithmeticFlags {
        ArithmeticFlags(
            carry: false,
            parity: hasEvenParity(result),
            auxiliaryCarry: false,
            zero: result == 0,
            sign: result & 0x80 != 0,
            overflow: false
        )
    }

    private static func logicalFlags16(_ result: UInt16) -> ArithmeticFlags {
        ArithmeticFlags(
            carry: false,
            parity: hasEvenParity(UInt8(truncatingIfNeeded: result)),
            auxiliaryCarry: false,
            zero: result == 0,
            sign: result & 0x8000 != 0,
            overflow: false
        )
    }

    /// The original 8086 does not mask CL, so this deliberately performs every
    /// requested one-bit iteration (up to 255). Undefined AF and multibit OF are
    /// preserved by returning no replacement value for those flags.
    private static func shiftRotate<Value>(
        _ value: Value,
        operation: ShiftRotateOperation,
        count: UInt8,
        carryIn: Bool
    ) -> ShiftRotateResult<Value>
    where Value: FixedWidthInteger & UnsignedInteger & Sendable {
        guard count != 0 else {
            return ShiftRotateResult(
                result: value,
                flags: ShiftRotateFlags(carry: nil, parity: nil, zero: nil, sign: nil, overflow: nil)
            )
        }

        let highBit: Value = Value(1) << (Value.bitWidth - 1)
        let originalSign = value & highBit != 0
        var result = value
        var carry = carryIn

        for _ in 0..<Int(count) {
            switch operation {
            case .rotateLeft:
                let outgoing = result & highBit != 0
                result = (result << 1) | (outgoing ? Value(1) : Value(0))
                carry = outgoing
            case .rotateRight:
                let outgoing = result & 1 != 0
                result = (result >> 1) | (outgoing ? highBit : Value(0))
                carry = outgoing
            case .rotateCarryLeft:
                let outgoing = result & highBit != 0
                result = (result << 1) | (carry ? Value(1) : Value(0))
                carry = outgoing
            case .rotateCarryRight:
                let outgoing = result & 1 != 0
                result = (result >> 1) | (carry ? highBit : Value(0))
                carry = outgoing
            case .shiftLeft:
                carry = result & highBit != 0
                result <<= 1
            case .shiftRight:
                carry = result & 1 != 0
                result >>= 1
            case .shiftArithmeticRight:
                carry = result & 1 != 0
                result = (result >> 1) | (result & highBit)
            }
        }

        let updatesStatus = operation.isShift
        let overflow = count == 1 ? originalSign != (result & highBit != 0) : nil
        return ShiftRotateResult(
            result: result,
            flags: ShiftRotateFlags(
                carry: carry,
                parity: updatesStatus ? hasEvenParity(UInt8(truncatingIfNeeded: result)) : nil,
                zero: updatesStatus ? result == 0 : nil,
                sign: updatesStatus ? result & highBit != 0 : nil,
                overflow: overflow
            )
        )
    }

    private static func hasEvenParity(_ byte: UInt8) -> Bool {
        byte.nonzeroBitCount.isMultiple(of: 2)
    }
}

extension CPUFlags {
    /// Replaces the byte-result status flags while preserving AF, CF and OF.
    /// AAM/AAD define only SF/ZF/PF; DAA/DAS use this after setting AF/CF.
    mutating func applySignZeroParity(_ result: UInt8) {
        self[.parity] = result.nonzeroBitCount.isMultiple(of: 2)
        self[.zero] = result == 0
        self[.sign] = result & 0x80 != 0
    }

    /// Applies an ALU result's flags, leaving control flags (TF/IF/DF) alone.
    mutating func applyArithmetic(_ flags: ArithmeticFlags) {
        self[.carry] = flags.carry
        applyArithmeticPreservingCarry(flags)
    }

    /// Applies an ALU result's flags except CF — INC/DEC semantics on the
    /// 8086, which update OF/SF/ZF/AF/PF but never touch the carry.
    mutating func applyArithmeticPreservingCarry(_ flags: ArithmeticFlags) {
        self[.parity] = flags.parity
        self[.auxiliaryCarry] = flags.auxiliaryCarry
        self[.zero] = flags.zero
        self[.sign] = flags.sign
        self[.overflow] = flags.overflow
    }

    mutating func applyShiftRotate(_ flags: ShiftRotateFlags) {
        if let carry = flags.carry { self[.carry] = carry }
        if let parity = flags.parity { self[.parity] = parity }
        if let zero = flags.zero { self[.zero] = zero }
        if let sign = flags.sign { self[.sign] = sign }
        if let overflow = flags.overflow { self[.overflow] = overflow }
    }
}
