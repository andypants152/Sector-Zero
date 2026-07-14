import Foundation
import Testing
@testable import Sector_Zero

@MainActor
@Suite(.serialized)
struct M57FloppyBIOSTests {
    private var firmwareURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware/sector-zero-bios-1.0.bin")
    }

    private func disk(_ geometry: FloppyDiskGeometry, seed: UInt8 = 0) -> Data {
        var bytes: [UInt8] = []
        bytes.reserveCapacity(geometry.byteCount)
        let sectors = geometry.byteCount / 512
        for sector in 0..<sectors {
            bytes.append(contentsOf: repeatElement(
                seed &+ UInt8(truncatingIfNeeded: sector),
                count: 512
            ))
        }
        return Data(bytes)
    }

    private func boot(_ media: Data? = nil) throws -> Machine {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))
        if let media { try machine.mountFloppyDisk(media) }
        let result = machine.runSlice(maxInstructions: 30_000)
        #expect(result.stopReason == .halted)
        return machine
    }

    @discardableResult
    private func call(
        _ machine: Machine,
        ax: UInt16,
        bx: UInt16 = 0,
        cx: UInt16 = 0,
        dx: UInt16 = 0,
        es: UInt16 = 0
    ) -> MachineRunSlice {
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, ax))
        _ = machine.cpu.execute(.movImmediateToRegister16(.bx, bx))
        _ = machine.cpu.execute(.movImmediateToRegister16(.cx, cx))
        _ = machine.cpu.execute(.movImmediateToRegister16(.dx, dx))
        machine.cpu.writeSegment(es, to: .es)
        machine.cpu.acceptInterrupt(type: 0x13, returnCS: machine.cpu.cs, returnIP: machine.cpu.ip)
        return machine.runSlice(maxInstructions: 100_000)
    }

    @Test("INT 13h discovers every supported media geometry through READ ID")
    func geometryParameters() throws {
        for geometry in FloppyDiskGeometry.supported {
            let machine = try boot(disk(geometry))
            let result = call(machine, ax: 0x0800)
            #expect(result.stopReason == .halted)
            #expect(!machine.cpu.flags[.carry])
            #expect(machine.cpu.registers[.ch] == UInt8(geometry.tracks - 1))
            #expect(machine.cpu.registers[.cl] & 0x3F == UInt8(geometry.sectorsPerTrack))
            #expect(machine.cpu.registers[.dh] == UInt8(geometry.heads - 1))
            #expect(machine.cpu.registers[.dl] == 1)
        }
    }

    @Test("Status persists failures and read-only operations report write protection")
    func statusAndWriteProtection() throws {
        let geometry = FloppyDiskGeometry.supported[3]
        let machine = try boot(disk(geometry))

        _ = call(machine, ax: 0x0301, bx: 0x2000, cx: 0x0001)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cpu.registers[.ah] == 0x03)
        #expect(machine.bus.readByte(at: 0x0441) == 0x03)

        _ = call(machine, ax: 0x0100)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cpu.registers[.ah] == 0x03)

        _ = call(machine, ax: 0x0000)
        #expect(!machine.cpu.flags[.carry])
        #expect(machine.bus.readByte(at: 0x0441) == 0)
    }

    @Test("Verify validates CHS and media without modifying the caller buffer")
    func verify() throws {
        let geometry = FloppyDiskGeometry.supported[3]
        let machine = try boot(disk(geometry))
        machine.bus.writeByte(0xCC, at: 0x3000)

        _ = call(machine, ax: 0x0402, bx: 0x3000, cx: 0x0008, dx: 0x0000)
        #expect(!machine.cpu.flags[.carry])
        #expect(machine.bus.readByte(at: 0x3000) == 0xCC)

        _ = call(machine, ax: 0x0401, bx: 0x3000, cx: 0x2801, dx: 0x0000)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cpu.registers[.ah] == 0x01)
    }

    @Test("No-media and media-status services report the physical absence")
    func noMedia() throws {
        let machine = try boot()
        _ = call(machine, ax: 0x0800)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cpu.registers[.ah] == 0x80)

        _ = call(machine, ax: 0x1600)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cpu.registers[.ah] == 0x06)
    }

    @Test("Reads cross track and head boundaries without crossing a DMA page")
    func trackCrossingRead() throws {
        let geometry = FloppyDiskGeometry(tracks: 40, heads: 2, sectorsPerTrack: 9, bytesPerSector: 512)
        let machine = try boot(disk(geometry, seed: 0x20))

        _ = call(machine, ax: 0x0203, bx: 0x2000, cx: 0x0008, dx: 0x0000)
        #expect(!machine.cpu.flags[.carry])
        #expect(machine.cpu.registers[.al] == 3)
        #expect(machine.bus.readByte(at: 0x2000) == 0x27)
        #expect(machine.bus.readByte(at: 0x2200) == 0x28)
        #expect(machine.bus.readByte(at: 0x2400) == 0x29)
    }

    @Test("A request crossing the DMA 64 KiB boundary is rejected before I/O")
    func dmaBoundary() throws {
        let geometry = FloppyDiskGeometry.supported[3]
        let machine = try boot(disk(geometry))
        let before = machine.snapshot().floppyController.recentReads.count
        _ = call(machine, ax: 0x0202, bx: 0xFF00, cx: 0x0001)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cpu.registers[.ah] == 0x09)
        #expect(machine.snapshot().floppyController.recentReads.count == before)
    }
}
