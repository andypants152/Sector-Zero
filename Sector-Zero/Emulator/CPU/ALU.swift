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
        let wide = UInt16(a) + UInt16(b)
        let result = UInt8(truncatingIfNeeded: wide)
        let flags = ArithmeticFlags(
            carry: wide > 0xFF,
            parity: hasEvenParity(result),
            auxiliaryCarry: (a & 0xF) + (b & 0xF) > 0xF,
            zero: result == 0,
            sign: result & 0x80 != 0,
            overflow: (a ^ result) & (b ^ result) & 0x80 != 0
        )
        return (result, flags)
    }

    static func add16(_ a: UInt16, _ b: UInt16) -> (result: UInt16, flags: ArithmeticFlags) {
        let wide = UInt32(a) + UInt32(b)
        let result = UInt16(truncatingIfNeeded: wide)
        let flags = ArithmeticFlags(
            carry: wide > 0xFFFF,
            parity: hasEvenParity(UInt8(truncatingIfNeeded: result)),
            auxiliaryCarry: (a & 0xF) + (b & 0xF) > 0xF,
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
        let result = a &- b
        let flags = ArithmeticFlags(
            carry: a < b,
            parity: hasEvenParity(result),
            auxiliaryCarry: (a & 0xF) < (b & 0xF),
            zero: result == 0,
            sign: result & 0x80 != 0,
            overflow: (a ^ b) & (a ^ result) & 0x80 != 0
        )
        return (result, flags)
    }

    static func subtract16(_ a: UInt16, _ b: UInt16) -> (result: UInt16, flags: ArithmeticFlags) {
        let result = a &- b
        let flags = ArithmeticFlags(
            carry: a < b,
            parity: hasEvenParity(UInt8(truncatingIfNeeded: result)),
            auxiliaryCarry: (a & 0xF) < (b & 0xF),
            zero: result == 0,
            sign: result & 0x8000 != 0,
            overflow: (a ^ b) & (a ^ result) & 0x8000 != 0
        )
        return (result, flags)
    }

    private static func hasEvenParity(_ byte: UInt8) -> Bool {
        byte.nonzeroBitCount.isMultiple(of: 2)
    }
}

extension CPUFlags {
    /// Applies an ALU result's flags, leaving control flags (TF/IF/DF) alone.
    mutating func applyArithmetic(_ flags: ArithmeticFlags) {
        self[.carry] = flags.carry
        self[.parity] = flags.parity
        self[.auxiliaryCarry] = flags.auxiliaryCarry
        self[.zero] = flags.zero
        self[.sign] = flags.sign
        self[.overflow] = flags.overflow
    }
}
