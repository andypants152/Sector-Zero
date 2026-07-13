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
        self.rawValue = rawValue | Self.reservedMask
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
                rawValue |= Self.reservedMask
            }
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

    private static let reservedMask: UInt16 = 0x0002
    private static let resetRawValue: UInt16 = reservedMask
}
