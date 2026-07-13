import Testing
@testable import Sector_Zero

private final class AddressLoadSpyBus: Bus {
    private var bytes: [UInt32: UInt8] = [:]
    private(set) var readAddresses: [UInt32] = []
    var onRead: (() -> Void)?

    func readByte(at address: UInt32) -> UInt8 {
        readAddresses.append(address)
        onRead?()
        return bytes[address, default: 0]
    }

    func writeByte(_ value: UInt8, at address: UInt32) {
        bytes[address] = value
    }

    func readWord(at address: UInt32) -> UInt16 {
        UInt16(readByte(at: address)) | UInt16(readByte(at: address + 1)) << 8
    }

    func writeWord(_ value: UInt16, at address: UInt32) {
        writeByte(UInt8(truncatingIfNeeded: value), at: address)
        writeByte(UInt8(value >> 8), at: address + 1)
    }
}

/// Milestone 30 — LEA address arithmetic and LDS/LES far-pointer loads.
struct AddressLoadTests {
    @Test("LEA decodes every 8086 addressing family")
    func leaAddressingFamilies() {
        var registers = RegisterFile()
        registers[.bx] = 0x1000
        registers[.bp] = 0x2000
        registers[.si] = 0x0010
        registers[.di] = 0x0020
        let decoder = InstructionDecoder()

        let cases: [(bytes: [UInt8], offset: UInt16, clocks: Int)] = [
            ([0x00],             0x1010, 7),  // [BX+SI]
            ([0x01],             0x1020, 8),  // [BX+DI]
            ([0x02],             0x2010, 8),  // [BP+SI]
            ([0x03],             0x2020, 7),  // [BP+DI]
            ([0x04],             0x0010, 5),  // [SI]
            ([0x05],             0x0020, 5),  // [DI]
            ([0x46, 0x00],       0x2000, 9),  // [BP+0]
            ([0x07],             0x1000, 5),  // [BX]
            ([0x06, 0x34, 0x12], 0x1234, 6),  // direct address
        ]

        for item in cases {
            var bytes = item.bytes
            #expect(decoder.decode(opcode: 0x8D, registers: registers) { bytes.removeFirst() }
                == .loadEffectiveAddress(destination: .ax, offset: item.offset, eaClocks: item.clocks))
        }
    }

    @Test("LEA displacement arithmetic wraps and register form is invalid")
    func leaWrapAndInvalidRegister() {
        var registers = RegisterFile()
        registers[.bx] = 0
        let decoder = InstructionDecoder()

        var wrapped: [UInt8] = [0x47, 0xFF] // LEA AX,[BX-1]
        #expect(decoder.decode(opcode: 0x8D, registers: registers) { wrapped.removeFirst() }
            == .loadEffectiveAddress(destination: .ax, offset: 0xFFFF, eaClocks: 9))

        var invalid: [UInt8] = [0xC1, 0xAA]
        #expect(decoder.decode(opcode: 0x8D, registers: registers) { invalid.removeFirst() } == .unknown(0x8D))
        #expect(invalid == [0xAA])
    }

    @Test("LEA never accesses memory or applies a segment override")
    func leaDoesNotReadMemory() {
        let bus = AddressLoadSpyBus()
        let cpu = CPU8086(bus: bus)
        cpu.setSegmentOverride(.es)
        let flags = cpu.flags

        let clocks = cpu.execute(.loadEffectiveAddress(destination: .di, offset: 0xBEEF, eaClocks: 12))

        #expect(cpu.di == 0xBEEF)
        #expect(cpu.flags == flags)
        #expect(bus.readAddresses.isEmpty)
        #expect(clocks == 14)
    }

    @Test("LES loads a little-endian pointer into a GP register and ES")
    func lesLoadsFarPointer() {
        let bus = AddressLoadSpyBus()
        let cpu = CPU8086(bus: bus)
        cpu.writeSegment(0x1000, to: .ds)
        bus.writeByte(0x34, at: 0x10040)
        bus.writeByte(0x12, at: 0x10041)
        bus.writeByte(0x78, at: 0x10042)
        bus.writeByte(0x56, at: 0x10043)
        let flags = cpu.flags

        let clocks = cpu.execute(.loadFarPointer(
            destination: .bx,
            segment: .es,
            source: .memory(EffectiveAddress(offset: 0x0040, defaultSegment: .ds)),
            eaClocks: 6
        ))

        #expect(cpu.bx == 0x1234)
        #expect(cpu.es == 0x5678)
        #expect(cpu.ds == 0x1000)
        #expect(cpu.flags == flags)
        #expect(bus.readAddresses == [0x10040, 0x10041, 0x10042, 0x10043])
        #expect(clocks == 22)
    }

    @Test("LDS honors an override and reads atomically before updating destinations")
    func ldsOverrideAndAtomicUpdate() {
        let bus = AddressLoadSpyBus()
        let cpu = CPU8086(bus: bus)
        _ = cpu.execute(.movImmediateToRegister16(.si, 0xAAAA))
        cpu.writeSegment(0x1111, to: .ds)
        cpu.writeSegment(0x2000, to: .es)
        cpu.setSegmentOverride(.es)

        bus.writeByte(0xCD, at: 0x20040)
        bus.writeByte(0xAB, at: 0x20041)
        bus.writeByte(0x56, at: 0x20042)
        bus.writeByte(0x34, at: 0x20043)
        // Conflicting bytes in the default segment catch a lost override.
        bus.writeByte(0x11, at: 0x11150)
        bus.writeByte(0x11, at: 0x11151)
        bus.writeByte(0x22, at: 0x11152)
        bus.writeByte(0x22, at: 0x11153)

        var statesDuringReads: [(UInt16, UInt16)] = []
        bus.onRead = { statesDuringReads.append((cpu.si, cpu.ds)) }
        let flags = cpu.flags
        let clocks = cpu.execute(.loadFarPointer(
            destination: .si,
            segment: .ds,
            source: .memory(EffectiveAddress(offset: 0x0040, defaultSegment: .ds)),
            eaClocks: 6
        ))

        #expect(statesDuringReads.count == 4)
        #expect(statesDuringReads.allSatisfy { $0.0 == 0xAAAA && $0.1 == 0x1111 })
        #expect(cpu.si == 0xABCD)
        #expect(cpu.ds == 0x3456)
        #expect(cpu.es == 0x2000)
        #expect(cpu.flags == flags)
        #expect(bus.readAddresses == [0x20040, 0x20041, 0x20042, 0x20043])
        #expect(clocks == 22)
    }

    @Test("LDS and LES decode memory only")
    func decodesFarPointerLoadsAndRejectsRegisters() {
        let decoder = InstructionDecoder()
        var lesBytes: [UInt8] = [0x1E, 0x40, 0x00]
        #expect(decoder.decode(opcode: 0xC4, registers: RegisterFile()) { lesBytes.removeFirst() }
            == .loadFarPointer(
                destination: .bx,
                segment: .es,
                source: .memory(EffectiveAddress(offset: 0x0040, defaultSegment: .ds)),
                eaClocks: 6
            ))

        var ldsBytes: [UInt8] = [0x2E, 0x40, 0x00]
        #expect(decoder.decode(opcode: 0xC5, registers: RegisterFile()) { ldsBytes.removeFirst() }
            == .loadFarPointer(
                destination: .bp,
                segment: .ds,
                source: .memory(EffectiveAddress(offset: 0x0040, defaultSegment: .ds)),
                eaClocks: 6
            ))

        for opcode: UInt8 in [0xC4, 0xC5] {
            var invalid: [UInt8] = [0xC0, 0xAA]
            #expect(decoder.decode(opcode: opcode, registers: RegisterFile()) { invalid.removeFirst() } == .unknown(opcode))
            #expect(invalid == [0xAA])
        }
    }
}
