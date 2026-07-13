import Foundation

enum CPUFlag: UInt16, CaseIterable, Identifiable, Sendable {
    case carry = 0
    case parity = 2
    case auxiliaryCarry = 4
    case zero = 6
    case sign = 7
    case trap = 8
    case interruptEnable = 9
    case direction = 10
    case overflow = 11

    var id: UInt16 { rawValue }

    var mask: UInt16 {
        1 << rawValue
    }

    var shortName: String {
        switch self {
        case .carry: "CF"
        case .parity: "PF"
        case .auxiliaryCarry: "AF"
        case .zero: "ZF"
        case .sign: "SF"
        case .trap: "TF"
        case .interruptEnable: "IF"
        case .direction: "DF"
        case .overflow: "OF"
        }
    }

    var displayName: String {
        switch self {
        case .carry: "Carry"
        case .parity: "Parity"
        case .auxiliaryCarry: "Aux Carry"
        case .zero: "Zero"
        case .sign: "Sign"
        case .trap: "Trap"
        case .interruptEnable: "Interrupt"
        case .direction: "Direction"
        case .overflow: "Overflow"
        }
    }
}

struct CPUFlags: Equatable, Sendable {
    private(set) var rawValue: UInt16

    init(rawValue: UInt16 = Self.resetRawValue) {
        self.rawValue = Self.normalized(rawValue)
    }

    subscript(flag: CPUFlag) -> Bool {
        get {
            rawValue & flag.mask != 0
        }
        set {
            if newValue {
                rawValue |= flag.mask
            } else {
                rawValue &= ~flag.mask
            }
            rawValue = Self.normalized(rawValue)
        }
    }

    mutating func update(_ flag: CPUFlag, to isSet: Bool) {
        self[flag] = isSet
    }

    var activeFlags: [CPUFlag] {
        CPUFlag.allCases.filter { self[$0] }
    }

    var hexValue: String {
        String(format: "%04X", rawValue)
    }

    /// The status flags exposed by LAHF in their architectural byte layout.
    /// Bit 1 is fixed high; reserved bits 3 and 5 are fixed low.
    var statusByte: UInt8 {
        UInt8(truncatingIfNeeded: rawValue)
    }

    /// SAHF replaces SF/ZF/AF/PF/CF from AH and preserves every control flag
    /// plus OF. Reserved bits are normalized rather than copied from AH.
    mutating func applyStatusByte(_ value: UInt8) {
        let statusMask = CPUFlag.sign.mask
            | CPUFlag.zero.mask
            | CPUFlag.auxiliaryCarry.mask
            | CPUFlag.parity.mask
            | CPUFlag.carry.mask
        rawValue = Self.normalized((rawValue & ~statusMask) | (UInt16(value) & statusMask))
    }

    /// Bits hard-wired to 1 on the 8086/8088 and impossible to clear: bit 1,
    /// plus bits 12–15. IOPL (12–13), NT (14) and MD (15) have no meaning on the
    /// 8086 and always read back as 1. Bits 3 and 5 are hard-wired to 0.
    /// Normalizing both policies keeps every `CPUFlags` value consistent with
    /// real 8086 silicon, including values restored by POPF.
    private static let reservedMask: UInt16 = 0xF002

    /// Reserved status-byte bits that always read as zero on the 8086.
    private static let reservedZeroMask: UInt16 = 0x0028

    /// After RESET the 8086 clears every condition and control flag, leaving only
    /// the hard-wired reserved bits set — i.e. the FLAGS register reads 0xF002.
    private static let resetRawValue: UInt16 = reservedMask

    private static func normalized(_ value: UInt16) -> UInt16 {
        (value | reservedMask) & ~reservedZeroMask
    }
}
