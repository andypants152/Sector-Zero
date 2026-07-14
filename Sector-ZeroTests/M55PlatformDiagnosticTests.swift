import Foundation
import Testing
@testable import Sector_Zero

@MainActor
@Suite(.serialized)
struct M55PlatformDiagnosticTests {
    private var firmwareDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware", isDirectory: true)
    }

    private var firmwareURL: URL {
        firmwareDirectory.appendingPathComponent("platform-diagnostic.bin")
    }

    private func machine(module: UInt8, disk: Data? = nil) throws -> Machine {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))
        machine.bus.writeByte(module, at: 0x04F0)
        if let disk {
            try machine.mountFloppyDisk(disk)
        }
        return machine
    }

    private func disk(firstSectorByte: UInt8 = 0xA5) -> Data {
        var bytes = Array(repeating: UInt8(0), count: 40 * 1 * 8 * 512)
        bytes.replaceSubrange(0..<512, with: repeatElement(firstSectorByte, count: 512))
        return Data(bytes)
    }

    private func completed(_ suite: UInt8, in snapshot: MachineSnapshot) -> Bool {
        snapshot.diagnosticPort.events.contains(DiagnosticEvent(
            suite: suite,
            testCase: DiagnosticEvent.suiteCompletionCase,
            status: .passed
        ))
    }

    @Test("The checked-in platform diagnostic ROM is reproducible and 8086-safe")
    func reproducibleBuild() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroPlatformDiagnostic-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = firmwareDirectory.appendingPathComponent("build-diagnostic-firmware.sh")
        process.arguments = ["platform-diagnostic", outputURL.path]
        try process.run()
        process.waitUntilExit()

        let bytes = try [UInt8](Data(contentsOf: outputURL))
        #expect(process.terminationStatus == 0)
        #expect(Data(bytes) == (try Data(contentsOf: firmwareURL)))
        #expect(bytes.count == 65_536)
        #expect(!bytes.indices.dropLast().contains {
            bytes[$0] == 0x0F && (0x80...0x8F).contains(bytes[$0 + 1])
        })
    }

    @Test("Memory-map diagnostic reaches low RAM, high conventional RAM, and ROM")
    func memoryModule() throws {
        let machine = try machine(module: 0x10)
        let result = machine.runSlice(maxInstructions: 2_000)
        #expect(result.stopReason == .halted)
        #expect(completed(0x10, in: result.snapshot))
        #expect(machine.bus.readWord(at: 0x0500) == 0x5AA5)
        #expect(machine.bus.readWord(at: 0x90000) == 0xA55A)
    }

    @Test("CGA diagnostic programs mode control and writes a visible summary")
    func videoModule() throws {
        let machine = try machine(module: 0x11)
        let result = machine.runSlice(maxInstructions: 2_000)
        #expect(result.stopReason == .halted)
        #expect(completed(0x11, in: result.snapshot))
        #expect(result.snapshot.video.modeControl == 0x29)
        #expect(result.snapshot.video.cells.prefix(2).map(\.codePoint) == Array("SZ".utf8))
    }

    @Test("PIC and PIT diagnostic receives a real IRQ0")
    func timerModule() throws {
        let machine = try machine(module: 0x12)
        let result = machine.runSlice(maxInstructions: 20_000)
        #expect(result.stopReason == .halted)
        #expect(completed(0x12, in: result.snapshot))
        #expect(machine.bus.readByte(at: 0x04F1) == 1)
    }

    @Test("Keyboard diagnostic waits for and acknowledges an XT make code")
    func keyboardModule() throws {
        let machine = try machine(module: 0x13)
        let waiting = machine.runSlice(maxInstructions: 512)
        #expect(waiting.stopReason == .instructionLimit)
        #expect(waiting.snapshot.diagnosticPort.events.last ==
            DiagnosticEvent(suite: 0x13, testCase: 0x01, status: .started))

        machine.postScanCode(0x1E)
        let result = machine.runSlice(maxInstructions: 4_096)
        #expect(result.stopReason == .halted)
        #expect(completed(0x13, in: result.snapshot))
        #expect(machine.bus.readByte(at: 0x04F2) == 0x1E)
    }

    @Test("Storage diagnostic reports absent media without inventing a drive")
    func storageWithoutMedia() throws {
        let machine = try machine(module: 0x14)
        let result = machine.runSlice(maxInstructions: 2_000)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot.diagnosticPort.events.contains(
            DiagnosticEvent(suite: 0x14, testCase: 0x01, status: .skipped)
        ))
        #expect(completed(0x14, in: result.snapshot))
    }

    @Test("Storage diagnostic transfers a sector through FDC, DMA, and IRQ6")
    func storageWithMedia() throws {
        let machine = try machine(module: 0x14, disk: disk())
        let result = machine.runSlice(maxInstructions: 30_000)
        #expect(result.stopReason == .halted)
        #expect(completed(0x14, in: result.snapshot))
        #expect(machine.bus.readByte(at: 0x2000) == 0xA5)
        #expect(machine.bus.readByte(at: 0x21FF) == 0xA5)
        #expect(result.snapshot.floppyController.recentReads.last?.dmaAddress == 0x2000)
        #expect(result.snapshot.floppyController.recentReads.last?.byteCount == 512)
    }
}
