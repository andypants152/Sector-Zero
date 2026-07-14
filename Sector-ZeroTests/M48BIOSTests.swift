import Foundation
import Testing
@testable import Sector_Zero

/// Milestone 48 — reproducible clean-room ROM, POST diagnostics, initialized
/// PC state, and the minimal BIOS services used by the boot path.
@MainActor
@Suite(.serialized)
struct M48BIOSTests {
    private struct FirmwareBuildError: Error, CustomStringConvertible {
        let status: Int32
        let output: String

        var description: String {
            "firmware build exited \(status): \(output)"
        }
    }

    private var firmwareDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware", isDirectory: true)
    }

    private var firmwareURL: URL {
        firmwareDirectory.appendingPathComponent("m48-bios.bin")
    }

    private func run(_ process: Process) async throws -> Int32 {
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        return try await withCheckedThrowingContinuation { continuation in
            process.terminationHandler = { completed in
                let data = output.fileHandleForReading.readDataToEndOfFile()
                let text = String(decoding: data, as: UTF8.self)
                if completed.terminationStatus == 0 {
                    continuation.resume(returning: completed.terminationStatus)
                } else {
                    continuation.resume(throwing: FirmwareBuildError(
                        status: completed.terminationStatus,
                        output: text
                    ))
                }
            }
            do {
                try process.run()
            } catch {
                continuation.resume(throwing: error)
            }
        }
    }

    private func bootMachine() throws -> Machine {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))
        let result = machine.runSlice(maxInstructions: 4_096)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot.cpu.fault == nil)
        #expect(result.snapshot.diagnosticPort.codes.contains(0xAA))
        return machine
    }

    private func callBIOS(_ vector: UInt8, on machine: Machine) -> MachineRunSlice {
        let returnCS = machine.cpu.cs
        let returnIP = machine.cpu.ip
        machine.cpu.acceptInterrupt(type: vector, returnCS: returnCS, returnIP: returnIP)
        return machine.runSlice(maxInstructions: 4_096)
    }

    @Test("The checked-in BIOS is exactly reproducible with the native toolchain")
    func reproducibleBuild() async throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroM48-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = firmwareDirectory.appendingPathComponent("build-m48-bios.sh")
        process.arguments = [outputURL.path]

        #expect(try await run(process) == 0)
        #expect(try Data(contentsOf: outputURL) == Data(contentsOf: firmwareURL))
        #expect(try Data(contentsOf: outputURL).count == 65_536)
    }

    @Test("POST initializes IVT, BDA, PIC, PIT, video, keyboard, and floppy state")
    func postState() throws {
        let machine = try bootMachine()
        let snapshot = machine.snapshot()

        #expect(snapshot.diagnosticPort.codes.starts(with: [0x10, 0x20, 0x30, 0x40, 0x50, 0xAA]))
        #expect(machine.bus.readWord(at: 0x0040) != 0)
        #expect(machine.bus.readWord(at: 0x0042) == 0xF000)
        #expect(machine.bus.readWord(at: 0x004C) != 0)
        #expect(machine.bus.readWord(at: 0x004E) == 0xF000)
        #expect(machine.bus.readByte(at: 0x0492) == 0)
        #expect(snapshot.interruptController.initialized)
        #expect(snapshot.interruptController.vectorBase == 0x08)
        #expect(snapshot.interruptController.interruptMask == 0xBC)
        #expect(snapshot.intervalTimer.channels[0].mode == .squareWave)
        #expect(snapshot.floppyController.phase == .idle)
        #expect(snapshot.video.modeControl == 0x29)

        let expectedText = Array("Sector Zero BIOS M48 - POST PASS".utf8)
        let text = snapshot.video.cells.prefix(expectedText.count).map(\.codePoint)
        #expect(text == expectedText)
    }

    @Test("Injected POST faults identify RAM, video, PIC, and floppy failures")
    func postFailureCodes() async throws {
        let outputDirectory = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroM48-failures-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: outputDirectory) }

        let process = Process()
        process.executableURL = firmwareDirectory.appendingPathComponent("build-m48-bios.sh")
        process.arguments = [outputDirectory.path, "all"]
        #expect(try await run(process) == 0)

        for component in [1, 2, 3, 6] {
            let outputURL = outputDirectory
                .appendingPathComponent("m48-bios-failure-\(component).bin")

            let machine = Machine()
            try machine.loadSystemROM(Data(contentsOf: outputURL))
            let result = machine.runSlice(maxInstructions: 4_096)
            #expect(result.stopReason == .halted)
            #expect(result.snapshot.cpu.fault == nil)
            #expect(result.snapshot.diagnosticPort.lastCode == 0xF0 | UInt8(component))

            let text = String(
                decoding: result.snapshot.video.cells.map(\.codePoint),
                as: UTF8.self
            )
            #expect(text.contains("Sector Zero BIOS M48 - POST FAIL"))
        }
    }

    @Test("INT 10h teletype and INT 1Ah clock services return through the IVT")
    func videoAndClockServices() throws {
        let machine = try bootMachine()
        let cursor = machine.bus.readWord(at: 0x0450)
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, 0x0E58)) // AH=0Eh, AL='X'.

        var result = callBIOS(0x10, on: machine)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot.video.cells[Int(cursor)].codePoint == UInt8(ascii: "X"))
        #expect(machine.bus.readWord(at: 0x0450) == cursor + 1)

        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, 0))
        result = callBIOS(0x1A, on: machine)
        #expect(result.stopReason == .halted)
        #expect(machine.cpu.cx == machine.bus.readWord(at: 0x046E))
        #expect(machine.cpu.dx == machine.bus.readWord(at: 0x046C))
        #expect(machine.cpu.registers[.ah] == 0)
        #expect(!machine.cpu.flags[.carry])
    }

    @Test("PC equipment, memory-size, serial, and printer BIOS contracts are deterministic")
    func platformServices() throws {
        let machine = try bootMachine()

        _ = callBIOS(0x11, on: machine)
        #expect(machine.cpu.ax == 0x0021) // One floppy drive and 80x25 color video.

        _ = callBIOS(0x12, on: machine)
        #expect(machine.cpu.ax == 640)

        _ = callBIOS(0x14, on: machine)
        #expect(machine.cpu.ax == 0x8000) // No serial adapter: timeout.

        _ = callBIOS(0x17, on: machine)
        #expect(machine.cpu.registers[.ah] == 0x01) // No printer: timeout.
    }

    @Test("IRQ1 feeds INT 16h and INT 13h reads a real image sector through DMA")
    func keyboardAndDiskServices() throws {
        var diskBytes = [UInt8](repeating: 0, count: 40 * 2 * 9 * 512)
        for index in 0..<512 { diskBytes[index] = UInt8(truncatingIfNeeded: index) }
        let machine = try bootMachine()
        try machine.mountFloppyDisk(Data(diskBytes))

        machine.postScanCode(0x23) // H make code.
        _ = machine.runSlice(maxInstructions: 64)
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, 0x0100))
        _ = callBIOS(0x16, on: machine)
        #expect(machine.cpu.registers[.al] == UInt8(ascii: "h"))
        #expect(machine.cpu.registers[.ah] == 0x23)
        #expect(!machine.cpu.flags[.zero])

        machine.postScanCode(0x1C) // Enter make code.
        _ = machine.runSlice(maxInstructions: 64)
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, 0x0000))
        _ = callBIOS(0x16, on: machine)
        #expect(machine.cpu.registers[.al] == 13)
        #expect(machine.cpu.registers[.ah] == 0x1C)

        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, 0x0201))
        _ = machine.cpu.execute(.movImmediateToRegister16(.bx, 0x7C00))
        _ = machine.cpu.execute(.movImmediateToRegister16(.cx, 0x0001))
        _ = machine.cpu.execute(.movImmediateToRegister16(.dx, 0x0000))
        machine.cpu.writeSegment(0, to: .es)
        let result = callBIOS(0x13, on: machine)

        #expect(result.stopReason == .halted)
        #expect(machine.cpu.registers[.ah] == 0)
        #expect(machine.cpu.registers[.al] == 1)
        #expect(!machine.cpu.flags[.carry])
        #expect((0..<512).allSatisfy {
            machine.bus.readByte(at: UInt32(0x7C00 + $0)) == UInt8(truncatingIfNeeded: $0)
        })
        #expect(machine.snapshot().dmaController.channel2.terminalCount)

        // A high conventional-memory destination must retain the DMA page.
        // This catches BIOS arithmetic that accidentally clobbers DL after
        // calculating the page register value for ES:BX.
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, 0x0201))
        _ = machine.cpu.execute(.movImmediateToRegister16(.bx, 0x0140))
        _ = machine.cpu.execute(.movImmediateToRegister16(.cx, 0x0001))
        _ = machine.cpu.execute(.movImmediateToRegister16(.dx, 0x0000))
        machine.cpu.writeSegment(0x9CC0, to: .es)
        _ = callBIOS(0x13, on: machine)

        #expect(machine.cpu.registers[.ah] == 0)
        #expect((0..<512).allSatisfy {
            machine.bus.readByte(at: UInt32(0x9CD40 + $0)) == UInt8(truncatingIfNeeded: $0)
        })
        #expect(machine.snapshot().dmaController.channel2.page == 0x09)
        #expect(machine.snapshot().floppyController.recentReads.last?.dmaAddress == 0x9CD40)
    }

    @Test("The diagnostic port is passive, bounded, and cleared by machine reset")
    func diagnosticPortContract() {
        let machine = Machine()
        for code in 0..<300 {
            machine.bus.writeIOByte(UInt8(truncatingIfNeeded: code), at: 0xE9)
        }
        #expect(machine.snapshot().diagnosticPort.codes.count == 256)
        #expect(machine.snapshot().diagnosticPort.lastCode == UInt8(truncatingIfNeeded: 299))
        #expect(machine.bus.readIOByte(at: 0xE9) == UInt8(truncatingIfNeeded: 299))

        machine.reset()
        #expect(machine.snapshot().diagnosticPort.codes.isEmpty)
        #expect(machine.snapshot().diagnosticPort.lastCode == nil)
    }
}
