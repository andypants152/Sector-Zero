import Foundation

enum AddressTranslator {
    static let physicalAddressMask: UInt32 = 0xFFFFF

    static func physicalAddress(segment: UInt16, offset: UInt16) -> UInt32 {
        ((UInt32(segment) << 4) + UInt32(offset)) & physicalAddressMask
    }
}
