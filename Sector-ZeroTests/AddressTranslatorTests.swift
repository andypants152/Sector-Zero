import Testing
@testable import Sector_Zero

/// The 8086 forms a 20-bit physical address as (segment << 4) + offset, wrapping
/// within the 1 MB space. These tests lock the translation that underpins the
/// reset vector (FFFF:0000 → FFFF0h).
struct AddressTranslatorTests {

    @Test("Reset vector FFFF:0000 maps to physical FFFF0h")
    func resetVectorTranslation() {
        #expect(AddressTranslator.physicalAddress(segment: 0xFFFF, offset: 0x0000) == 0xFFFF0)
    }

    @Test("segment:offset uses (segment << 4) + offset")
    func standardTranslation() {
        #expect(AddressTranslator.physicalAddress(segment: 0x1000, offset: 0x0100) == 0x10100)
    }

    @Test("Zero segment leaves the offset unchanged")
    func zeroSegment() {
        #expect(AddressTranslator.physicalAddress(segment: 0x0000, offset: 0x1234) == 0x01234)
    }

    @Test("Address wraps within the 20-bit space (no A20 gate)")
    func wrapAroundMasking() {
        // FFFF:FFFF = 0xFFFF0 + 0xFFFF = 0x10FFEF, which exceeds 20 bits and wraps.
        #expect(AddressTranslator.physicalAddress(segment: 0xFFFF, offset: 0xFFFF) == 0x0FFEF)
    }
}
