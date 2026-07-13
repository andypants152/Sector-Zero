import Foundation

protocol Bus: AnyObject {
    func readByte(at address: UInt32) -> UInt8
    func writeByte(_ value: UInt8, at address: UInt32)
    func readWord(at address: UInt32) -> UInt16
    func writeWord(_ value: UInt16, at address: UInt32)
    func readIOByte(at port: UInt16) -> UInt8
    func readIOWord(at port: UInt16) -> UInt16
    func writeIOByte(_ value: UInt8, at port: UInt16)
    func writeIOWord(_ value: UInt16, at port: UInt16)
}

/// Test and specialist buses that only model memory get deterministic open-bus
/// I/O behavior without needing empty method implementations.
extension Bus {
    func readIOByte(at port: UInt16) -> UInt8 { 0xFF }
    func readIOWord(at port: UInt16) -> UInt16 { 0xFFFF }
    func writeIOByte(_ value: UInt8, at port: UInt16) {}
    func writeIOWord(_ value: UInt16, at port: UInt16) {}
}

final class EmulatorBus: Bus {
    private let memory: Memory
    private var ioDevices: [UInt16: any IOPortDevice] = [:]

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

    /// Maps an inclusive port range to one device. Overlapping mappings are a
    /// configuration error rather than silently changing machine topology.
    func mapPortDevice(_ device: any IOPortDevice, to ports: ClosedRange<UInt16>) {
        precondition(ports.allSatisfy { ioDevices[$0] == nil }, "I/O port range overlaps an existing device")
        for port in ports {
            ioDevices[port] = device
        }
    }

    func readIOByte(at port: UInt16) -> UInt8 {
        ioDevices[port]?.readByte(from: port) ?? 0xFF
    }

    func readIOWord(at port: UInt16) -> UInt16 {
        ioDevices[port]?.readWord(from: port) ?? 0xFFFF
    }

    func writeIOByte(_ value: UInt8, at port: UInt16) {
        ioDevices[port]?.writeByte(value, to: port)
    }

    func writeIOWord(_ value: UInt16, at port: UInt16) {
        ioDevices[port]?.writeWord(value, to: port)
    }
}
