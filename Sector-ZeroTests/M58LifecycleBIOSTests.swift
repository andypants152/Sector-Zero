import Foundation
import Testing
@testable import Sector_Zero

@MainActor
@Suite(.serialized)
struct M58LifecycleBIOSTests {
    private var firmwareURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware/sector-zero-bios-1.0.bin")
    }

    private func disk(bootSector: [UInt8]) -> Data {
        var bytes = Array(repeating: UInt8(0), count: 40 * 1 * 8 * 512)
        bytes.replaceSubrange(0..<512, with: bootSector)
        return Data(bytes)
    }

    private func bootSector(program: [UInt8]) -> [UInt8] {
        var sector = Array(repeating: UInt8(0), count: 512)
        sector.replaceSubrange(0..<program.count, with: program)
        sector[510] = 0x55
        sector[511] = 0xAA
        return sector
    }

    private func machine(media: Data? = nil) throws -> Machine {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))
        if let media { try machine.mountFloppyDisk(media) }
        let result = machine.runSlice(maxInstructions: 100_000)
        #expect(result.stopReason == .halted)
        return machine
    }

    @discardableResult
    private func call(
        _ vector: UInt8,
        on machine: Machine,
        ax: UInt16 = 0,
        cx: UInt16 = 0,
        dx: UInt16 = 0,
        limit: Int = 100_000
    ) -> MachineRunSlice {
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, ax))
        _ = machine.cpu.execute(.movImmediateToRegister16(.cx, cx))
        _ = machine.cpu.execute(.movImmediateToRegister16(.dx, dx))
        machine.cpu.acceptInterrupt(type: vector, returnCS: machine.cpu.cs, returnIP: machine.cpu.ip)
        return machine.runSlice(maxInstructions: limit)
    }

    private func post(_ scan: UInt8, to machine: Machine) {
        machine.postScanCode(scan)
        _ = machine.runSlice(maxInstructions: 1_024)
    }

    @Test("INT 1Ah sets and gets ticks while consuming the midnight flag")
    func clockSetGetAndRollover() throws {
        let machine = try machine()
        _ = call(0x1A, on: machine, ax: 0x0100, cx: 0x0012, dx: 0x3456)
        #expect(machine.bus.readWord(at: 0x046C) == 0x3456)
        #expect(machine.bus.readWord(at: 0x046E) == 0x0012)

        _ = call(0x1A, on: machine, ax: 0x0000)
        #expect(machine.cpu.cx == 0x0012)
        #expect(machine.cpu.dx == 0x3456)
        #expect(machine.cpu.registers[.al] == 0)

        machine.bus.writeWord(0x00AF, at: 0x046C)
        machine.bus.writeWord(0x0018, at: 0x046E)
        machine.cpu.acceptInterrupt(type: 0x08, returnCS: machine.cpu.cs, returnIP: machine.cpu.ip)
        _ = machine.runSlice(maxInstructions: 256)
        _ = call(0x1A, on: machine, ax: 0x0000)
        #expect(machine.cpu.cx == 0)
        #expect(machine.cpu.dx == 0)
        #expect(machine.cpu.registers[.al] == 1)
        _ = call(0x1A, on: machine, ax: 0x0000)
        #expect(machine.cpu.registers[.al] == 0)
    }

    @Test("INT 19h reloads and transfers to a valid boot sector")
    func bootstrapRestart() throws {
        let sector = bootSector(program: [0xB0, 0xC9, 0xE6, 0xE9, 0xF4])
        let machine = try machine(media: disk(bootSector: sector))
        #expect(machine.snapshot().diagnosticPort.codes.filter { $0 == 0xC9 }.count == 1)
        machine.bus.writeByte(0x90, at: 0x7C00)

        let result = call(0x19, on: machine)
        #expect(result.stopReason == .halted)
        #expect(machine.bus.readByte(at: 0x7C00) == 0xB0)
        #expect(result.snapshot.diagnosticPort.codes.filter { $0 == 0xC9 }.count == 2)
    }

    @Test("INT 19h failure reaches the ROM INT 18h endpoint")
    func noBootPath() throws {
        let machine = try machine()
        let failures = machine.snapshot().diagnosticPort.codes.filter { $0 == 0xE1 }.count
        let result = call(0x19, on: machine)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot.diagnosticPort.codes.filter { $0 == 0xE1 }.count == failures + 1)
        #expect(result.snapshot.diagnosticPort.lastCode == 0xE8)
    }

    @Test("Ctrl-Alt-Del selects warm POST and preserves conventional RAM")
    func warmRestart() throws {
        let machine = try machine()
        machine.bus.writeWord(0xCAFE, at: 0x0600)
        post(0x1D, to: machine)
        post(0x38, to: machine)
        machine.postScanCode(0x53)
        let result = machine.runSlice(maxInstructions: 100_000)
        #expect(result.stopReason == .halted)
        #expect(machine.bus.readWord(at: 0x0600) == 0xCAFE)
        #expect(result.snapshot.diagnosticPort.codes.contains(0x11))
        #expect(machine.bus.readWord(at: 0x0472) == 0)
    }

    @Test("INT 15h reports zero extended memory and rejects AT-only services")
    func systemServices() throws {
        let machine = try machine()
        _ = call(0x15, on: machine, ax: 0x8800)
        #expect(machine.cpu.ax == 0)
        #expect(!machine.cpu.flags[.carry])

        _ = call(0x15, on: machine, ax: 0x8600)
        #expect(machine.cpu.registers[.ah] == 0x86)
        #expect(machine.cpu.flags[.carry])
    }
}
