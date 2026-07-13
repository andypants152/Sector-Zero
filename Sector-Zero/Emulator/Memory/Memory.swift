import Foundation

enum MemoryAccessError: Error, Equatable {
    case addressOutOfBounds(UInt32)
}

final class Memory {
    static let addressableSize = 1_048_576

    private var bytes: [UInt8]

    init(size: Int = Memory.addressableSize) {
        self.bytes = Array(repeating: 0, count: size)
    }

    var size: Int {
        bytes.count
    }

    func readByte(at address: UInt32) throws -> UInt8 {
        try bytes[index(for: address)]
    }

    func writeByte(_ value: UInt8, at address: UInt32) throws {
        bytes[try index(for: address)] = value
    }

    func readWord(at address: UInt32) throws -> UInt16 {
        try validateWordAccess(at: address)
        let lowByte = UInt16(try readByte(at: address))
        let highByte = UInt16(try readByte(at: address + 1))
        return lowByte | (highByte << 8)
    }

    func writeWord(_ value: UInt16, at address: UInt32) throws {
        try validateWordAccess(at: address)
        try writeByte(UInt8(value & 0x00FF), at: address)
        try writeByte(UInt8((value & 0xFF00) >> 8), at: address + 1)
    }

    private func index(for address: UInt32) throws -> Int {
        guard address < UInt32(bytes.count) else {
            throw MemoryAccessError.addressOutOfBounds(address)
        }

        return Int(address)
    }

    private func validateWordAccess(at address: UInt32) throws {
        guard bytes.count >= 2, address < UInt32(bytes.count - 1) else {
            throw MemoryAccessError.addressOutOfBounds(address)
        }
    }
}
