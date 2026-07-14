import Foundation
import Testing
@testable import Sector_Zero

@MainActor
@Suite(.serialized)
struct M59BIOSConformanceTests {
    private var firmwareDirectory: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware", isDirectory: true)
    }

    private func run(image: URL) throws -> MachineRunSlice {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareDirectory.appendingPathComponent("sector-zero-bios-1.0.bin")))
        try machine.mountFloppyDisk(Data(contentsOf: image))
        return machine.runSlice(maxInstructions: 250_000)
    }

    @Test("The checked-in conformance image is reproducible and bootable")
    func reproducibleBuild() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroConformance-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = firmwareDirectory.appendingPathComponent("build-bios-conformance.sh")
        process.arguments = [output.path]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)
        #expect(try Data(contentsOf: output) == Data(contentsOf: firmwareDirectory.appendingPathComponent("bios-conformance.img")))
        #expect(try Data(contentsOf: output).count == 1_474_560)
    }

    @Test("Stage one loads stage two and all BIOS conformance suites pass")
    func conformancePass() throws {
        let result = try run(image: firmwareDirectory.appendingPathComponent("bios-conformance.img"))
        #expect(result.stopReason == .halted)
        let events = result.snapshot.diagnosticPort.events
        #expect(events.contains(DiagnosticEvent(suite: 0x20, testCase: 0xFF, status: .passed)))
        #expect(events.contains(DiagnosticEvent(suite: 0x21, testCase: 0xFF, status: .passed)))
        #expect(!events.contains { $0.status == .failed })
        let text = String(decoding: result.snapshot.video.cells.map(\.codePoint), as: UTF8.self)
        #expect(text.contains("BIOS CONFORMANCE PASS"))
        #expect(result.snapshot.floppyController.recentReads.contains { $0.sector == 2 })
    }

    @Test("The injected guest failure uses the same authoritative event protocol")
    func conformanceFailure() throws {
        let output = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroConformanceFailure-\(UUID().uuidString).img")
        defer { try? FileManager.default.removeItem(at: output) }
        let process = Process()
        process.executableURL = firmwareDirectory.appendingPathComponent("build-bios-conformance.sh")
        process.arguments = [output.path, "failure"]
        try process.run()
        process.waitUntilExit()
        #expect(process.terminationStatus == 0)

        let result = try run(image: output)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot.diagnosticPort.events.contains(
            DiagnosticEvent(suite: 0x21, testCase: 0x7F, status: .failed)
        ))
        #expect(result.snapshot.diagnosticPort.events.contains(
            DiagnosticEvent(suite: 0x21, testCase: 0xFF, status: .failed)
        ))
    }
}
