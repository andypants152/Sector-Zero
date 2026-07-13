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

    private static func hasEvenParity(_ byte: UInt8) -> Bool {
        byte.nonzeroBitCount.isMultiple(of: 2)
    }
}

extension CPUFlags {
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
}
