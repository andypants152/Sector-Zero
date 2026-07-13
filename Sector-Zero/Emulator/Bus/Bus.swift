import Foundation

protocol Bus: AnyObject {
    func readByte(at address: UInt32) -> UInt8
    func writeByte(_ value: UInt8, at address: UInt32)
    func readWord(at address: UInt32) -> UInt16
    func writeWord(_ value: UInt16, at address: UInt32)
}

final class EmulatorBus: Bus {
    private let memory: Memory

    init(memory: Memory) {
        self.memory = memory
    }

    func readByte(at address: UInt32) -> UInt8 {
        (try? memory.readByte(at: address)) ?? 0
    }

    func writeByte(_ value: UInt8, at address: UInt32) {
        try? memory.writeByte(value, at: address)
    }

    func readWord(at address: UInt32) -> UInt16 {
        let lowByte = UInt16(readByte(at: address))
        let highByte = UInt16(readByte(at: address + 1))
        return lowByte | (highByte << 8)
    }

    func writeWord(_ value: UInt16, at address: UInt32) {
        writeByte(UInt8(value & 0x00FF), at: address)
        writeByte(UInt8((value & 0xFF00) >> 8), at: address + 1)
    }
}
