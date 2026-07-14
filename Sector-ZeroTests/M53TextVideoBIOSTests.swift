import Foundation
import Testing
@testable import Sector_Zero

/// Milestone 53 — complete BIOS text services for the installed 80x25 CGA.
@MainActor
@Suite(.serialized)
struct M53TextVideoBIOSTests {
    private var firmwareURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware/sector-zero-bios-1.0.bin")
    }

    private func bootDisk() -> Data {
        var sector = [UInt8](repeating: 0, count: 512)
        sector.replaceSubrange(0..<3, with: [0xF4, 0xEB, 0xFD]) // HLT; JMP HLT.
        sector[510] = 0x55
        sector[511] = 0xAA
        var disk = [UInt8](repeating: 0, count: 40 * 2 * 9 * 512)
        disk.replaceSubrange(0..<512, with: sector)
        return Data(disk)
    }

    private func machineAtBootSector() throws -> Machine {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))
        try machine.mountFloppyDisk(bootDisk())
        let result = machine.runSlice(maxInstructions: 50_000, breakpoints: [0x07C00])
        #expect(result.stopReason == .breakpoint(0x07C00))
        return machine
    }

    @discardableResult
    private func callVideo(_ machine: Machine) -> MachineRunSlice {
        machine.cpu.acceptInterrupt(
            type: 0x10,
            returnCS: machine.cpu.cs,
            returnIP: machine.cpu.ip
        )
        let result = machine.runSlice(maxInstructions: 30_000, traceLimit: 16)
        #expect(
            result.stopReason == .halted,
            "\(MachineDebugger.exportTrace(result.trace))"
        )
        #expect(result.snapshot.cpu.fault == nil)
        return result
    }

    private func setRegisters(
        _ machine: Machine,
        ax: UInt16,
        bx: UInt16 = 0,
        cx: UInt16 = 0,
        dx: UInt16 = 0
    ) {
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, ax))
        _ = machine.cpu.execute(.movImmediateToRegister16(.bx, bx))
        _ = machine.cpu.execute(.movImmediateToRegister16(.cx, cx))
        _ = machine.cpu.execute(.movImmediateToRegister16(.dx, dx))
    }

    private func cellAddress(page: Int = 0, row: Int, column: Int) -> UInt32 {
        0xB8000 + UInt32(page * 0x1000 + (row * 80 + column) * 2)
    }

    private func word(_ machine: Machine, page: Int = 0, row: Int, column: Int) -> UInt16 {
        machine.bus.readWord(at: cellAddress(page: page, row: row, column: column))
    }

    @Test("The INT 10h dispatcher contains no post-8086 near conditional encoding")
    func dispatcherUses8086Branches() throws {
        let machine = try machineAtBootSector()
        let handlerOffset = machine.bus.readWord(at: 0x0040)
        let dispatcher = try machine.inspectMemory(
            at: 0xF0000 + UInt32(handlerOffset),
            byteCount: 96
        )

        // On an 8086, 0Fh is POP CS rather than the prefix for 386 near Jcc.
        let containsNearConditional = dispatcher.indices.dropLast().contains { index in
            dispatcher[index] == 0x0F && (0x80...0x8F).contains(dispatcher[index + 1])
        }
        #expect(!containsNearConditional)
    }

    @Test("Mode set clears CGA pages, resets BDA state, and mode query reports 80x25 page zero")
    func modeSetAndQuery() throws {
        let machine = try machineAtBootSector()
        machine.bus.writeWord(0x4F58, at: cellAddress(page: 3, row: 24, column: 79))

        setRegisters(machine, ax: 0x0003)
        let result = callVideo(machine)
        #expect(word(machine, page: 3, row: 24, column: 79) == 0x0720)
        #expect(machine.bus.readByte(at: 0x0449) == 3)
        #expect(machine.bus.readWord(at: 0x044A) == 80)
        #expect(machine.bus.readWord(at: 0x044E) == 0)
        #expect(machine.bus.readByte(at: 0x0462) == 0)
        #expect(result.snapshot.video.modeControl == 0x29)
        #expect(result.snapshot.video.displayStartAddress == 0)
        #expect(result.snapshot.video.cursorPosition == 0)

        setRegisters(machine, ax: 0x0F00, bx: 0x00A5)
        _ = callVideo(machine)
        #expect(machine.cpu.ax == 0x5003)
        #expect(machine.cpu.registers[.bh] == 0)
        #expect(machine.cpu.registers[.bl] == 0xA5)
    }

    @Test("Cursor shape, per-page positions, active page, and CRTC state stay synchronized")
    func cursorAndPageServices() throws {
        let machine = try machineAtBootSector()

        setRegisters(machine, ax: 0x0100, cx: 0x0205)
        _ = callVideo(machine)
        setRegisters(machine, ax: 0x0200, bx: 0x0100, dx: 0x0203)
        _ = callVideo(machine)
        setRegisters(machine, ax: 0x0501)
        let result = callVideo(machine)

        #expect(machine.bus.readWord(at: 0x0452) == 0x0203)
        #expect(machine.bus.readWord(at: 0x0460) == 0x0205)
        #expect(machine.bus.readByte(at: 0x0462) == 1)
        #expect(machine.bus.readWord(at: 0x044E) == 0x1000)
        #expect(result.snapshot.video.displayStartAddress == 0x0800)
        #expect(result.snapshot.video.cursorPosition == 2 * 80 + 3)
        #expect(result.snapshot.video.cursorStartLine == 2)
        #expect(result.snapshot.video.cursorEndLine == 5)

        setRegisters(machine, ax: 0x0300, bx: 0x0100)
        _ = callVideo(machine)
        #expect(machine.cpu.cx == 0x0205)
        #expect(machine.cpu.dx == 0x0203)
    }

    @Test("Character services write attributes, preserve attributes, read cells, and leave the cursor")
    func characterServices() throws {
        let machine = try machineAtBootSector()
        setRegisters(machine, ax: 0x0200, dx: 0x0102)
        _ = callVideo(machine)

        setRegisters(machine, ax: 0x0941, bx: 0x001E, cx: 3)
        _ = callVideo(machine)
        #expect(word(machine, row: 1, column: 2) == 0x1E41)
        #expect(word(machine, row: 1, column: 3) == 0x1E41)
        #expect(word(machine, row: 1, column: 4) == 0x1E41)
        #expect(machine.bus.readWord(at: 0x0450) == 0x0102)

        machine.bus.writeWord(0x2A31, at: cellAddress(row: 1, column: 2))
        machine.bus.writeWord(0x3B32, at: cellAddress(row: 1, column: 3))
        setRegisters(machine, ax: 0x0A5A, cx: 2)
        _ = callVideo(machine)
        #expect(word(machine, row: 1, column: 2) == 0x2A5A)
        #expect(word(machine, row: 1, column: 3) == 0x3B5A)

        setRegisters(machine, ax: 0x0800)
        _ = callVideo(machine)
        #expect(machine.cpu.ax == 0x2A5A)
    }

    @Test("Window scrolling moves only the rectangle and clears with the requested attribute")
    func windowScrolling() throws {
        let machine = try machineAtBootSector()
        for row in 1...3 {
            for column in 2...4 {
                let character = UInt16(UInt8(ascii: "A")) + UInt16(row - 1)
                machine.bus.writeWord(0x1700 | character, at: cellAddress(row: row, column: column))
            }
        }
        machine.bus.writeWord(0x6E58, at: cellAddress(row: 1, column: 1))

        setRegisters(machine, ax: 0x0601, bx: 0x1E00, cx: 0x0102, dx: 0x0304)
        _ = callVideo(machine)
        #expect(word(machine, row: 1, column: 2) == 0x1742)
        #expect(word(machine, row: 2, column: 2) == 0x1743)
        #expect(word(machine, row: 3, column: 2) == 0x1E20)
        #expect(word(machine, row: 1, column: 1) == 0x6E58)

        setRegisters(machine, ax: 0x0701, bx: 0x2B00, cx: 0x0102, dx: 0x0304)
        _ = callVideo(machine)
        #expect(word(machine, row: 1, column: 2) == 0x2B20)
        #expect(word(machine, row: 2, column: 2) == 0x1742)
        #expect(word(machine, row: 3, column: 2) == 0x1743)

        setRegisters(machine, ax: 0x0600, bx: 0x4C00, cx: 0x0102, dx: 0x0304)
        _ = callVideo(machine)
        #expect((1...3).allSatisfy { row in
            (2...4).allSatisfy { column in
                word(machine, row: row, column: column) == 0x4C20
            }
        })
    }

    @Test("Teletype controls wrap, scroll, and update the BDA and hardware cursor")
    func teletypeEdges() throws {
        let machine = try machineAtBootSector()
        setRegisters(machine, ax: 0x0200, dx: 0x184F)
        _ = callVideo(machine)
        setRegisters(machine, ax: 0x0E58)
        var result = callVideo(machine)

        #expect(word(machine, row: 23, column: 79) & 0x00FF == UInt16(UInt8(ascii: "X")))
        #expect(word(machine, row: 24, column: 79) == 0x0720)
        #expect(machine.bus.readWord(at: 0x0450) == 0x1800)
        #expect(result.snapshot.video.cursorPosition == 24 * 80)

        setRegisters(machine, ax: 0x0E41)
        _ = callVideo(machine)
        setRegisters(machine, ax: 0x0E08)
        _ = callVideo(machine)
        setRegisters(machine, ax: 0x0E0D)
        _ = callVideo(machine)
        #expect(machine.bus.readWord(at: 0x0450) == 0x1800)

        setRegisters(machine, ax: 0x0200, dx: 0x0A05)
        _ = callVideo(machine)
        setRegisters(machine, ax: 0x0E0A)
        result = callVideo(machine)
        #expect(machine.bus.readWord(at: 0x0450) == 0x0B05)
        #expect(result.snapshot.video.cursorPosition == 11 * 80 + 5)
    }
}
