import Foundation
import Testing
@testable import Sector_Zero

/// Milestone 49 — authentic sector-zero loading, boot handoff, and deterministic
/// debugger surfaces used to diagnose pre-OS failures.
@MainActor
struct M49BootTests {
    private var firmwareURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware/m48-bios.bin")
    }

    private func disk(bootSector: [UInt8]) -> Data {
        precondition(bootSector.count == 512)
        var bytes = [UInt8](repeating: 0, count: 40 * 2 * 9 * 512)
        bytes.replaceSubrange(0..<512, with: bootSector)
        return Data(bytes)
    }

    private func diagnosticBootSector(message: String, validSignature: Bool = true) -> [UInt8] {
        var sector: [UInt8] = []
        for byte in message.utf8 {
            // MOV AX,0E00h|character; INT 10h
            sector.append(contentsOf: [0xB8, byte, 0x0E, 0xCD, 0x10])
        }
        sector.append(0xF4) // HLT
        sector.append(contentsOf: repeatElement(0, count: 510 - sector.count))
        sector.append(validSignature ? 0x55 : 0x00)
        sector.append(validSignature ? 0xAA : 0x00)
        return sector
    }

    private func machine(with bootSector: [UInt8]) throws -> Machine {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))
        try machine.mountFloppyDisk(disk(bootSector: bootSector))
        return machine
    }

    @Test("BIOS loads sector zero and stops at an exact pre-execution breakpoint")
    func bootHandoffContract() throws {
        let sector = diagnosticBootSector(message: "BOOT OK")
        let machine = try machine(with: sector)
        let result = machine.runSlice(
            maxInstructions: 8_192,
            breakpoints: [0x07C00],
            traceLimit: 64
        )

        #expect(result.stopReason == .breakpoint(0x07C00))
        #expect(result.snapshot.diagnosticPort.lastCode == 0xB2)
        #expect(try machine.inspectMemory(at: 0x07C00, byteCount: 512) == sector)
        #expect(machine.cpu.cs == 0)
        #expect(machine.cpu.ip == 0x7C00)
        #expect(machine.cpu.ds == 0)
        #expect(machine.cpu.es == 0)
        #expect(machine.cpu.ss == 0)
        #expect(machine.cpu.sp == 0x7C00)
        #expect(machine.cpu.ax == 0)
        #expect(machine.cpu.bx == 0)
        #expect(machine.cpu.cx == 0)
        #expect(machine.cpu.dx == 0)
        #expect(machine.cpu.si == 0)
        #expect(machine.cpu.di == 0)
        #expect(machine.cpu.bp == 0)
        #expect(!machine.cpu.flags[.interruptEnable])
    }

    @Test("An unmodified diagnostic boot sector executes and prints through BIOS video")
    func diagnosticSectorExecutes() throws {
        let machine = try machine(with: diagnosticBootSector(message: "BOOT OK"))
        let result = machine.runSlice(maxInstructions: 8_192)

        #expect(result.stopReason == .halted)
        #expect(result.snapshot.cpu.fault == nil)
        let screen = String(decoding: result.snapshot.video.cells.map(\.codePoint), as: UTF8.self)
        #expect(screen.contains("BOOT OK"))
    }

    @Test("Missing media and a bad boot signature report distinct guest-visible failures")
    func bootFailures() throws {
        let missingMedia = Machine()
        try missingMedia.loadSystemROM(Data(contentsOf: firmwareURL))
        var result = missingMedia.runSlice(maxInstructions: 8_192)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot.diagnosticPort.lastCode == 0xE1)
        var screen = String(decoding: result.snapshot.video.cells.map(\.codePoint), as: UTF8.self)
        #expect(screen.contains("BOOT READ FAIL"))

        let badSignature = try machine(with: diagnosticBootSector(message: "NO", validSignature: false))
        result = badSignature.runSlice(maxInstructions: 8_192)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot.diagnosticPort.lastCode == 0xE2)
        screen = String(decoding: result.snapshot.video.cells.map(\.codePoint), as: UTF8.self)
        #expect(screen.contains("BOOT SIGNATURE FAIL"))
    }

    @Test("Bounded execution, physical memory inspection, and trace export are deterministic")
    func debuggerContracts() throws {
        let machine = Machine()
        try machine.bus.loadBytes([0x90, 0xF4], at: 0xFFFF0)

        var result = machine.runSlice(
            maxInstructions: 4,
            breakpoints: [0xFFFF0],
            traceLimit: 4
        )
        #expect(result.stopReason == .breakpoint(0xFFFF0))
        #expect(result.executedBoundaries == 0)
        #expect(result.trace.isEmpty)

        result = machine.runSlice(maxInstructions: 1, traceLimit: 1)
        #expect(result.stopReason == .instructionLimit)
        #expect(result.executedBoundaries == 1)
        #expect(try machine.inspectMemory(at: 0xFFFF0, byteCount: 2) == [0x90, 0xF4])
        #expect(MachineDebugger.exportTrace(result.trace) == """
        CYCLE       CS:IP      PHYS   OP
        0000000000  FFFF:0000  FFFF0  90

        """)

        #expect(throws: MemoryInspectionError.self) {
            try machine.inspectMemory(at: 0xFFFFF, byteCount: 2)
        }
    }

    @Test("Workspace breakpoint and bounded-run controls publish debugger state")
    func workspaceDebuggerControls() throws {
        let machine = Machine()
        try machine.bus.loadBytes([0x90, 0xF4], at: 0xFFFF0)
        let workspace = SectorZeroWorkspace(machine: machine)

        workspace.toggleBreakpointAtCurrentAddress()
        var result = workspace.runBounded(maxInstructions: 4)
        #expect(result?.stopReason == .breakpoint(0xFFFF0))
        #expect(workspace.machineCondition.label == "BREAK")

        workspace.toggleBreakpointAtCurrentAddress()
        result = workspace.runBounded(maxInstructions: 1)
        #expect(result?.stopReason == .instructionLimit)
        #expect(workspace.instructionTrace.count == 1)
        #expect(workspace.exportedInstructionTrace.contains("FFFF:0000"))
    }
}
