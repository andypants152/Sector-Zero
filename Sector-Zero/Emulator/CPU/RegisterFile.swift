import Foundation

/// A 16-bit general-purpose register, in the 8086's `reg` encoding order.
enum Register16: UInt8, CaseIterable, Sendable {
    case ax = 0, cx, dx, bx, sp, bp, si, di
}

/// An 8-bit register half, in the 8086's `reg` encoding order. Only AX–DX have
/// addressable halves; AH is the high byte of AX (bits 15–8), AL the low.
enum Register8: UInt8, CaseIterable, Sendable {
    case al = 0, cl, dl, bl, ah, ch, dh, bh

    /// The word register this byte register is half of.
    var parent: Register16 {
        Register16(rawValue: rawValue & 0b011)!
    }

    /// True for AH/CH/DH/BH — the high halves (bits 15–8) of their parents.
    var isHighByte: Bool {
        rawValue >= 4
    }
}

/// Storage for the 8086's general-purpose registers, addressable as words
/// (AX…DI) or as byte halves of the first four (AL/AH…DL/DH). A value type:
/// copying a register file copies the machine state it represents.
struct RegisterFile: Equatable, Sendable {
    private var storage = [UInt16](repeating: 0, count: Register16.allCases.count)

    subscript(register: Register16) -> UInt16 {
        get { storage[Int(register.rawValue)] }
        set { storage[Int(register.rawValue)] = newValue }
    }

    subscript(register: Register8) -> UInt8 {
        get {
            let word = self[register.parent]
            return register.isHighByte ? UInt8(word >> 8) : UInt8(word & 0xFF)
        }
        set {
            let word = self[register.parent]
            self[register.parent] = register.isHighByte
                ? (word & 0x00FF) | (UInt16(newValue) << 8)
                : (word & 0xFF00) | UInt16(newValue)
        }
    }

    mutating func reset() {
        storage = [UInt16](repeating: 0, count: storage.count)
    }
}
