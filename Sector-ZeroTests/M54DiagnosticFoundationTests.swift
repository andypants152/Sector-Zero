import Foundation
import Testing
@testable import Sector_Zero

@MainActor
@Suite(.serialized)
struct M54DiagnosticFoundationTests {
    private var firmwareDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware", isDirectory: true)
    }

    private var firmwareURL: URL {
        firmwareDirectory.appendingPathComponent("reset-smoke.bin")
    }

    private let passingEvents = [
        DiagnosticEvent(suite: 0x01, testCase: 0x00, status: .started),
        DiagnosticEvent(suite: 0x01, testCase: 0x01, status: .passed),
        DiagnosticEvent(suite: 0x01, testCase: 0x02, status: .passed),
        DiagnosticEvent(suite: 0x01, testCase: 0x03, status: .passed),
        DiagnosticEvent(suite: 0x01, testCase: 0x04, status: .passed),
        DiagnosticEvent(suite: 0x01, testCase: 0x05, status: .skipped),
        DiagnosticEvent(suite: 0x01, testCase: 0x06, status: .passed),
        DiagnosticEvent(suite: 0x01, testCase: 0xFF, status: .passed),
    ]

    @Test("Diagnostic events decode around legacy bytes and incomplete tails")
    func eventDecoder() {
        let bytes: [UInt8] = [
            0x10, 0x53, 0x01, 0x02, 0x01,
            0x20, 0x53, 0x03, 0x04, 0x02,
            0x53, 0x05,
        ]
        #expect(DiagnosticEventDecoder.decode(bytes) == [
            DiagnosticEvent(suite: 0x01, testCase: 0x02, status: .passed),
            DiagnosticEvent(suite: 0x03, testCase: 0x04, status: .failed),
        ])
    }

    @Test("The checked-in reset smoke ROM is reproducible")
    func reproducibleBuild() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroResetSmoke-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = firmwareDirectory.appendingPathComponent("build-diagnostic-firmware.sh")
        process.arguments = ["reset-smoke", outputURL.path]
        try process.run()
        process.waitUntilExit()

        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: outputURL) == Data(contentsOf: firmwareURL))
        #expect(try Data(contentsOf: outputURL).count == 512)
    }

    @Test("Reset smoke ROM reports the exact passing sequence and halts")
    func resetSmokeSequence() throws {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))

        let result = machine.runSlice(maxInstructions: 512)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot.cpu.fault == nil)
        #expect(result.snapshot.diagnosticPort.events == passingEvents)
        #expect(machine.bus.readWord(at: 0x0500) == 0x55AA)
        #expect(machine.bus.readWord(at: 0x0502) == 0xAA55)
        #expect(result.snapshot.cpu.ss == 0)
        #expect(result.snapshot.cpu.sp == 0x7000)
    }

    @Test("Reset smoke ROM's destructive variant proves ROM write protection")
    func romWriteProtection() throws {
        let outputURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroResetSmokeROMWrite-\(UUID().uuidString).bin")
        defer { try? FileManager.default.removeItem(at: outputURL) }

        let process = Process()
        process.executableURL = firmwareDirectory.appendingPathComponent("build-diagnostic-firmware.sh")
        process.arguments = ["reset-smoke", outputURL.path, "rom-write"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: outputURL))
        let result = machine.runSlice(maxInstructions: 512)
        guard case .memoryMapViolation = result.stopReason else {
            Issue.record("expected ROM write violation, got \(result.stopReason)")
            return
        }
        #expect(result.snapshot.diagnosticPort.events.last ==
            DiagnosticEvent(suite: 0x01, testCase: 0x05, status: .started))
    }
}
