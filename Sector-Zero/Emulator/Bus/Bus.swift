import Foundation

protocol Bus: AnyObject {
    func readByte(at address: UInt32) -> UInt8
    func writeByte(_ value: UInt8, at address: UInt32)
    func readWord(at address: UInt32) -> UInt16
    func writeWord(_ value: UInt16, at address: UInt32)
}

final class EmulatorBus: Bus {
    // Temporary open-bus stub. RAM, ROM, video memory, and devices will attach
    // here instead of being reached directly by CPU code.
    func readByte(at address: UInt32) -> UInt8 {
        0
    }

    func writeByte(_ value: UInt8, at address: UInt32) {
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
