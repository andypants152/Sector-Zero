import Foundation
import Testing
@testable import Sector_Zero

@MainActor
@Suite(.serialized)
struct FixedDiskBIOSTests {
    private var firmwareURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware/sector-zero-bios-1.0.bin")
    }

    private func disk(cylinders: Int = 2) -> Data {
        let geometry = FixedDiskGeometry(cylinders: cylinders, heads: 4, sectorsPerTrack: 17, bytesPerSector: 512)
        return Data((0..<geometry.byteCount).map { UInt8(truncatingIfNeeded: $0 / 512) })
    }

    private func boot() throws -> Machine {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))
        try machine.mountHardDisk(disk())
        let result = machine.runSlice(maxInstructions: 50_000)
        #expect(result.stopReason == .halted)
        #expect(machine.bus.readByte(at: 0x0475) == 1)
        return machine
    }

    @discardableResult
    private func call(
        _ machine: Machine,
        ax: UInt16,
        bx: UInt16 = 0,
        cx: UInt16 = 0,
        dx: UInt16 = 0x0080,
        es: UInt16 = 0
    ) -> MachineRunSlice {
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, ax))
        _ = machine.cpu.execute(.movImmediateToRegister16(.bx, bx))
        _ = machine.cpu.execute(.movImmediateToRegister16(.cx, cx))
        _ = machine.cpu.execute(.movImmediateToRegister16(.dx, dx))
        machine.cpu.writeSegment(es, to: .es)
        machine.cpu.acceptInterrupt(type: 0x13, returnCS: machine.cpu.cs, returnIP: machine.cpu.ip)
        return machine.runSlice(maxInstructions: 20_000)
    }

    @Test("Fixed-disk parameters expose IDENTIFY geometry and one installed drive")
    func parameters() throws {
        let machine = try boot()
        _ = call(machine, ax: 0x0800)
        #expect(!machine.cpu.flags[.carry])
        #expect(machine.cpu.registers[.ch] == 1)
        #expect(machine.cpu.registers[.cl] & 0x3F == 17)
        #expect(machine.cpu.registers[.dh] == 3)
        #expect(machine.cpu.registers[.dl] == 1)
    }

    @Test("INT 13h reads and writes C through the ISA block adapter")
    func readWrite() throws {
        let machine = try boot()
        _ = call(machine, ax: 0x0201, bx: 0x3000, cx: 0x0002)
        #expect(!machine.cpu.flags[.carry])
        #expect(machine.bus.readByte(at: 0x3000) == 1)

        for index in 0..<512 { machine.bus.writeByte(0xC3, at: 0x3200 + UInt32(index)) }
        _ = call(machine, ax: 0x0301, bx: 0x3200, cx: 0x0002)
        #expect(!machine.cpu.flags[.carry])
        _ = call(machine, ax: 0x0201, bx: 0x3400, cx: 0x0002)
        #expect(!machine.cpu.flags[.carry])
        #expect((0..<512).allSatisfy { machine.bus.readByte(at: 0x3400 + UInt32($0)) == 0xC3 })
        #expect(machine.snapshot().blockDiskController.writeCount == 1)
    }

    @Test("Fixed-disk status reports DMA-window and absent-media errors")
    func errors() throws {
        let machine = try boot()
        _ = call(machine, ax: 0x0202, bx: 0xFF00, cx: 0x0001)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cpu.registers[.ah] == 0x09)

        machine.ejectHardDisk()
        _ = call(machine, ax: 0x0000)
        #expect(machine.cpu.flags[.carry])
        #expect(machine.cpu.registers[.ah] == 0x80)
    }
}
