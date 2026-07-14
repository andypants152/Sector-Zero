import Foundation
import Testing
@testable import Sector_Zero

@MainActor
struct ISABlockDiskControllerTests {
    private func image(cylinders: Int = 2) -> Data {
        let geometry = FixedDiskGeometry(cylinders: cylinders, heads: 4, sectorsPerTrack: 17, bytesPerSector: 512)
        return Data((0..<geometry.byteCount).map { UInt8(truncatingIfNeeded: $0 / 512) })
    }

    private func program(
        _ machine: Machine,
        cylinder: UInt16 = 0,
        head: UInt8 = 0,
        sector: UInt8 = 1,
        count: UInt8 = 1,
        address: UInt32 = 0x2000
    ) {
        let base = ISABlockDiskController.basePort
        machine.bus.writeIOByte(0, at: base + 1)
        machine.bus.writeIOByte(UInt8(truncatingIfNeeded: cylinder), at: base + 2)
        machine.bus.writeIOByte(UInt8(cylinder >> 8), at: base + 3)
        machine.bus.writeIOByte(head, at: base + 4)
        machine.bus.writeIOByte(sector, at: base + 5)
        machine.bus.writeIOByte(count, at: base + 6)
        machine.bus.writeIOByte(UInt8(truncatingIfNeeded: address), at: base + 7)
        machine.bus.writeIOByte(UInt8(truncatingIfNeeded: address >> 8), at: base + 8)
        machine.bus.writeIOByte(UInt8(truncatingIfNeeded: address >> 16), at: base + 9)
    }

    @Test("IDENTIFY publishes exact raw-image CHS geometry")
    func identify() throws {
        let machine = Machine()
        try machine.mountHardDisk(image(cylinders: 2))
        let base = ISABlockDiskController.basePort
        machine.bus.writeIOByte(ISABlockDiskController.commandIdentify, at: base)

        #expect(machine.bus.readIOByte(at: base) == ISABlockDiskController.statusReady)
        #expect(machine.bus.readIOByte(at: base + 2) == 1)
        #expect(machine.bus.readIOByte(at: base + 3) == 0)
        #expect(machine.bus.readIOByte(at: base + 4) == 3)
        #expect(machine.bus.readIOByte(at: base + 5) == 17)
    }

    @Test("Read and write commands transfer sectors through conventional memory")
    func readWrite() throws {
        let machine = Machine()
        try machine.mountHardDisk(image())
        let base = ISABlockDiskController.basePort
        program(machine, head: 1, sector: 2, address: 0x3200)
        machine.bus.writeIOByte(ISABlockDiskController.commandRead, at: base)
        #expect((0..<512).allSatisfy { machine.bus.readByte(at: 0x3200 + UInt32($0)) == 18 })

        for index in 0..<512 { machine.bus.writeByte(0xA5, at: 0x3400 + UInt32(index)) }
        program(machine, head: 1, sector: 2, address: 0x3400)
        machine.bus.writeIOByte(ISABlockDiskController.commandWrite, at: base)
        program(machine, head: 1, sector: 2, address: 0x3600)
        machine.bus.writeIOByte(ISABlockDiskController.commandRead, at: base)

        #expect((0..<512).allSatisfy { machine.bus.readByte(at: 0x3600 + UInt32($0)) == 0xA5 })
        #expect(machine.snapshot().blockDiskController.writeCount == 1)
    }

    @Test("Writes persist to the mounted project image")
    func persistentWrite() throws {
        let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try image().write(to: url)
        defer { try? FileManager.default.removeItem(at: url) }
        let machine = Machine()
        try machine.mountHardDisk(Data(contentsOf: url), fileURL: url)
        for index in 0..<512 { machine.bus.writeByte(0x5A, at: 0x4000 + UInt32(index)) }
        program(machine, sector: 1, address: 0x4000)
        machine.bus.writeIOByte(ISABlockDiskController.commandWrite, at: ISABlockDiskController.basePort)

        let persisted = try Data(contentsOf: url)
        #expect(persisted.prefix(512) == Data(repeating: 0x5A, count: 512))
        #expect(machine.snapshot().blockDiskController.persistenceError == nil)
    }

    @Test("Missing media and 64 KiB boundary violations return BIOS-compatible status")
    func errors() throws {
        let machine = Machine()
        let base = ISABlockDiskController.basePort
        program(machine)
        machine.bus.writeIOByte(ISABlockDiskController.commandRead, at: base)
        #expect(machine.bus.readIOByte(at: base) == ISABlockDiskController.statusNotReady)

        try machine.mountHardDisk(image())
        program(machine, count: 2, address: 0xFF00)
        machine.bus.writeIOByte(ISABlockDiskController.commandRead, at: base)
        #expect(machine.bus.readIOByte(at: base) == ISABlockDiskController.statusDMABoundary)
    }
}
