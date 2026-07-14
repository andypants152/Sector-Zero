import Foundation
import Testing
@testable import Sector_Zero

/// Milestone 52 — conventional IVT/BDA publication and top-of-ROM identity.
@MainActor
struct M52BIOSFoundationTests {
    private var firmwareURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware/m48-bios.bin")
    }

    private func bootSector() -> Data {
        var sector = [UInt8](repeating: 0, count: 512)
        sector[0] = 0xF4
        sector[510] = 0x55
        sector[511] = 0xAA
        var disk = [UInt8](repeating: 0, count: 40 * 2 * 9 * 512)
        disk.replaceSubrange(0..<512, with: sector)
        return Data(disk)
    }

    private func bootToHandoff() throws -> Machine {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))
        try machine.mountFloppyDisk(bootSector())
        let result = machine.runSlice(
            maxInstructions: 12_000,
            breakpoints: [0x07C00]
        )
        #expect(result.stopReason == .breakpoint(0x07C00))
        #expect(result.snapshot.cpu.fault == nil)
        return machine
    }

    @Test("Every IVT vector has a firmware endpoint and installed services override the fallback")
    func initializedInterruptTable() throws {
        let machine = try bootToHandoff()
        let entries = (0..<256).map { vector in
            let address = UInt32(vector * 4)
            return (
                offset: machine.bus.readWord(at: address),
                segment: machine.bus.readWord(at: address + 2)
            )
        }

        #expect(entries.allSatisfy { $0.segment == 0xF000 })
        #expect(entries.allSatisfy { $0.offset != 0 })
        #expect(entries[0x15] == entries[0x18])
        #expect(entries[0x10] != entries[0x15])
        #expect(entries[0x13] != entries[0x15])
        #expect(entries[0x16] != entries[0x15])
        #expect(entries[0x1A] != entries[0x15])
    }

    @Test("An unimplemented interrupt returns through the default handler without changing caller state")
    func defaultInterruptReturns() throws {
        let machine = try bootToHandoff()
        let returnCS = machine.cpu.cs
        let returnIP = machine.cpu.ip
        let originalSP = machine.cpu.sp
        let originalAX = machine.cpu.ax
        let originalFlags = machine.cpu.flags

        machine.cpu.acceptInterrupt(type: 0x15, returnCS: returnCS, returnIP: returnIP)
        machine.step()

        #expect(machine.cpu.cs == returnCS)
        #expect(machine.cpu.ip == returnIP)
        #expect(machine.cpu.sp == originalSP)
        #expect(machine.cpu.ax == originalAX)
        #expect(machine.cpu.flags == originalFlags)
        #expect(machine.cpu.fault == nil)
    }

    @Test("POST publishes canonical installed-platform and mode-3 BDA fields")
    func biosDataArea() throws {
        let machine = try bootToHandoff()

        #expect(machine.bus.readWord(at: 0x0410) == 0x0021)
        #expect(machine.bus.readWord(at: 0x0413) == 640)
        #expect(machine.bus.readByte(at: 0x0441) == 0)
        #expect(machine.bus.readByte(at: 0x0449) == 3)
        #expect(machine.bus.readWord(at: 0x044A) == 80)
        #expect(machine.bus.readWord(at: 0x044C) == 0x1000)
        #expect(machine.bus.readWord(at: 0x044E) == 0)
        #expect(machine.bus.readWord(at: 0x0460) == 0x0607)
        #expect(machine.bus.readByte(at: 0x0462) == 0)
        #expect(machine.bus.readWord(at: 0x0463) == 0x03D4)
        #expect(machine.bus.readByte(at: 0x0465) == 0x29)
        #expect(machine.bus.readByte(at: 0x0466) == 0)
        #expect(machine.bus.readByte(at: 0x0470) == 0)
        #expect(machine.bus.readWord(at: 0x0472) == 0)
    }

    @Test("The conventional top-of-ROM identity contains a stable date and PC model byte")
    func romIdentity() throws {
        let machine = try bootToHandoff()
        let date = try machine.inspectMemory(at: 0xFFFF5, byteCount: 8)

        #expect(String(decoding: date, as: UTF8.self) == "07/13/26")
        #expect(machine.bus.readByte(at: 0xFFFFD) == 0)
        #expect(machine.bus.readByte(at: 0xFFFFE) == 0xFF)
    }
}
