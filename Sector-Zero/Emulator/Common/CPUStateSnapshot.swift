import Foundation

struct CPUStateSnapshot: Equatable, Sendable {
    let ax: UInt16
    let bx: UInt16
    let cx: UInt16
    let dx: UInt16
    let si: UInt16
    let di: UInt16
    let sp: UInt16
    let bp: UInt16
    let cs: UInt16
    let ds: UInt16
    let es: UInt16
    let ss: UInt16
    let ip: UInt16
    let flags: CPUFlags

    var generalRegisters: [RegisterValue] {
        [
            RegisterValue(name: "AX", value: ax),
            RegisterValue(name: "BX", value: bx),
            RegisterValue(name: "CX", value: cx),
            RegisterValue(name: "DX", value: dx)
        ]
    }

    var indexRegisters: [RegisterValue] {
        [
            RegisterValue(name: "SI", value: si),
            RegisterValue(name: "DI", value: di)
        ]
    }

    var pointerRegisters: [RegisterValue] {
        [
            RegisterValue(name: "SP", value: sp),
            RegisterValue(name: "BP", value: bp)
        ]
    }

    var segmentRegisters: [RegisterValue] {
        [
            RegisterValue(name: "CS", value: cs),
            RegisterValue(name: "DS", value: ds),
            RegisterValue(name: "ES", value: es),
            RegisterValue(name: "SS", value: ss)
        ]
    }
}

struct RegisterValue: Identifiable, Equatable, Sendable {
    let name: String
    let value: UInt16

    var id: String { name }

    var hexValue: String {
        String(format: "%04X", value)
    }
}
