import Foundation

protocol Device: AnyObject {
}

/// A deterministic device driven from completed CPU/interrupt boundaries.
/// Devices receive elapsed emulated clocks in batches; they never own threads
/// or depend on host wall-clock time.
protocol ClockedDevice: Device {
    func advance(by clocks: Int)
    func reset()
}

extension ClockedDevice {
    func reset() {}
}

/// A device exposed through the 8086's independent 16-bit I/O-port space.
/// Word callbacks are explicit so a 16-bit device can observe one architectural
/// transfer rather than being forced through two byte callbacks.
protocol IOPortDevice: Device {
    func readByte(from port: UInt16) -> UInt8
    func readWord(from port: UInt16) -> UInt16
    func writeByte(_ value: UInt8, to port: UInt16)
    func writeWord(_ value: UInt16, to port: UInt16)
}

extension IOPortDevice {
    func readWord(from port: UInt16) -> UInt16 {
        let low = UInt16(readByte(from: port))
        let high = UInt16(readByte(from: port &+ 1))
        return low | high << 8
    }

    func writeWord(_ value: UInt16, to port: UInt16) {
        writeByte(UInt8(truncatingIfNeeded: value), to: port)
        writeByte(UInt8(value >> 8), to: port &+ 1)
    }
}
