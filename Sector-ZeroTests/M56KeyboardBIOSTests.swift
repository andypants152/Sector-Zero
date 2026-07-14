import Foundation
import Testing
@testable import Sector_Zero

@MainActor
@Suite(.serialized)
struct M56KeyboardBIOSTests {
    private var firmwareURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware/sector-zero-bios-1.0.bin")
    }

    private func bootMachine() throws -> Machine {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))
        let result = machine.runSlice(maxInstructions: 30_000)
        #expect(result.stopReason == .halted)
        return machine
    }

    @discardableResult
    private func call(_ function: UInt8, on machine: Machine, cx: UInt16? = nil) -> MachineRunSlice {
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, UInt16(function) << 8))
        if let cx {
            _ = machine.cpu.execute(.movImmediateToRegister16(.cx, cx))
        }
        machine.cpu.acceptInterrupt(type: 0x16, returnCS: machine.cpu.cs, returnIP: machine.cpu.ip)
        return machine.runSlice(maxInstructions: 4_096)
    }

    private func post(_ scan: UInt8, to machine: Machine) {
        machine.postScanCode(scan)
        _ = machine.runSlice(maxInstructions: 512)
    }

    @Test("POST publishes the canonical XT keyboard BDA buffer")
    func bufferFoundation() throws {
        let machine = try bootMachine()
        #expect(machine.bus.readByte(at: 0x0417) == 0)
        #expect(machine.bus.readByte(at: 0x0418) == 0)
        #expect(machine.bus.readWord(at: 0x041A) == 0x001E)
        #expect(machine.bus.readWord(at: 0x041C) == 0x001E)
        #expect(machine.bus.readWord(at: 0x0480) == 0x001E)
        #expect(machine.bus.readWord(at: 0x0482) == 0x003E)
    }

    @Test("INT 16h insertion, peek, read, wrap, and full policy preserve FIFO order")
    func circularBuffer() throws {
        let machine = try bootMachine()
        for value in 1...15 {
            _ = call(0x05, on: machine, cx: UInt16(0x1000 + value))
            #expect(machine.cpu.registers[.al] == 0)
        }
        _ = call(0x05, on: machine, cx: 0xFFFF)
        #expect(machine.cpu.registers[.al] == 1)

        _ = call(0x01, on: machine)
        #expect(machine.cpu.ax == 0x1001)
        #expect(!machine.cpu.flags[.zero])
        _ = call(0x00, on: machine)
        #expect(machine.cpu.ax == 0x1001)

        for value in 16...20 {
            _ = call(0x05, on: machine, cx: UInt16(0x1000 + value))
        }
        var values: [UInt16] = []
        while machine.bus.readWord(at: 0x041A) != machine.bus.readWord(at: 0x041C) {
            _ = call(0x00, on: machine)
            values.append(machine.cpu.ax)
        }
        #expect(values == Array(0x1002...0x1010))
    }

    @Test("IRQ1 translates Shift, Caps Lock, Ctrl, Alt, and lock-state edges")
    func modifiersAndLocks() throws {
        let machine = try bootMachine()

        post(0x2A, to: machine) // Left Shift make.
        post(0x23, to: machine) // H.
        _ = call(0x00, on: machine)
        #expect(machine.cpu.ax == 0x2348) // 'H'
        post(0xAA, to: machine) // Left Shift break.

        post(0x3A, to: machine) // Caps make toggles on.
        post(0x3A, to: machine) // Typematic repeat must not toggle again.
        post(0xBA, to: machine)
        post(0x23, to: machine)
        _ = call(0x00, on: machine)
        #expect(machine.cpu.ax == 0x2348)

        post(0x1D, to: machine) // Ctrl make.
        post(0x2E, to: machine) // C.
        _ = call(0x00, on: machine)
        #expect(machine.cpu.ax == 0x2E03)
        post(0x9D, to: machine)

        post(0x38, to: machine) // Alt make.
        post(0x2D, to: machine) // X produces scan-only word.
        _ = call(0x00, on: machine)
        #expect(machine.cpu.ax == 0x2D00)
        post(0xB8, to: machine)

        post(0x45, to: machine) // Num Lock.
        post(0xC5, to: machine)
        post(0x46, to: machine) // Scroll Lock.
        post(0xC6, to: machine)
        _ = call(0x02, on: machine)
        #expect(machine.cpu.registers[.al] & 0x70 == 0x70)
    }

    @Test("INT 16h blocking read resumes after a real IRQ1")
    func blockingRead() throws {
        let machine = try bootMachine()
        let waiting = call(0x00, on: machine)
        #expect(waiting.stopReason == .halted)

        post(0x1C, to: machine)
        #expect(machine.cpu.ax == 0x1C0D)
        #expect(machine.bus.readWord(at: 0x041A) == machine.bus.readWord(at: 0x041C))
    }

    @Test("Ctrl-Alt-Del enters the firmware reset path")
    func controlAltDelete() throws {
        let machine = try bootMachine()
        post(0x1D, to: machine)
        post(0x38, to: machine)
        machine.postScanCode(0x53)
        let result = machine.runSlice(maxInstructions: 30_000)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot.diagnosticPort.codes.contains(0x11))
    }
}
