import Foundation
import Testing
@testable import Sector_Zero

@MainActor
struct WorkspaceFirmwareTests {
    /// A 16-byte image is top-aligned over FFFF0h, so its first byte is the
    /// instruction the reset vector fetches.
    private let haltImage = Data([0xF4] + Array(repeating: UInt8(0x90), count: 15))

    private func makeTemporaryRoot() throws -> URL {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroWorkspaceFirmware-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    @Test("An empty machine reports NO ROM instead of READY")
    func emptyMachineReportsNoROM() {
        let workspace = SectorZeroWorkspace(machine: Machine())

        #expect(workspace.machineSnapshot.loadedSystemROMByteCount == 0)
        #expect(workspace.machineCondition == MachineCondition(label: "NO ROM", severity: .held))
        #expect(workspace.machineConditionDetail == "No firmware loaded — the machine has nothing to execute")
    }

    @Test("A machine with firmware reports READY")
    func firmwareLoadedMachineReportsReady() throws {
        let machine = Machine()
        try machine.loadSystemROM(haltImage)
        let workspace = SectorZeroWorkspace(machine: machine)

        #expect(workspace.machineCondition == MachineCondition(label: "READY", severity: .ready))
        #expect(workspace.machineConditionDetail == nil)
    }

    @Test("Configuring firmware installs it in the package, loads it, and resets the machine")
    func configureFirmwareInstallsAndLoads() throws {
        let defaultsSuite = "SectorZeroTests.ConfigureFirmware.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SectorZeroWorkspace(userDefaults: userDefaults)
        #expect(workspace.createProject(named: "Configurable", in: root))
        workspace.step() // fault on the empty ROM so reset has something to clear
        #expect(workspace.machineSnapshot.cpu.fault != nil)

        let sourceURL = root.appendingPathComponent("bios.bin", isDirectory: false)
        try haltImage.write(to: sourceURL)
        #expect(workspace.configureFirmware(from: sourceURL))

        #expect(workspace.machineSnapshot.loadedSystemROMByteCount == 16)
        #expect(workspace.machine.bus.readByte(at: 0xFFFF0) == 0xF4)
        #expect(workspace.currentProject?.metadata.firmwarePath == "firmware/bios.bin")
        #expect(workspace.machineSnapshot.cpu.fault == nil)
        #expect(workspace.machineSnapshot.cpu.ip == 0)
        #expect(workspace.machineCondition == MachineCondition(label: "READY", severity: .ready))

        let installedURL = try #require(workspace.currentProject?.configuredFirmwareURL)
        #expect(FileManager.default.fileExists(atPath: installedURL.path))
        #expect(installedURL.path.hasPrefix(try #require(workspace.currentProject?.projectURL.path)))

        let reopened = SectorZeroWorkspace(userDefaults: userDefaults)
        #expect(reopened.openProject(at: try #require(workspace.currentProject?.projectURL)))
        #expect(reopened.machineSnapshot.loadedSystemROMByteCount == 16)
        #expect(reopened.machineCondition == MachineCondition(label: "READY", severity: .ready))
    }

    @Test("An oversized firmware image is rejected without touching the project")
    func rejectsOversizedFirmwareImage() throws {
        let defaultsSuite = "SectorZeroTests.RejectFirmware.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SectorZeroWorkspace(userDefaults: userDefaults)
        #expect(workspace.createProject(named: "Oversized", in: root))

        let sourceURL = root.appendingPathComponent("big.bin", isDirectory: false)
        try Data(count: 65 * 1024).write(to: sourceURL)

        #expect(!workspace.configureFirmware(from: sourceURL))
        #expect(workspace.errorMessage != nil)
        #expect(workspace.currentProject?.metadata.firmwarePath == nil)
        #expect(workspace.machineSnapshot.loadedSystemROMByteCount == 0)
    }

    @Test("Configuring firmware without an open machine fails with an explanation")
    func requiresOpenProject() throws {
        let defaultsSuite = "SectorZeroTests.NoProjectFirmware.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }

        let workspace = SectorZeroWorkspace(userDefaults: userDefaults)
        let sourceURL = root.appendingPathComponent("bios.bin", isDirectory: false)
        try haltImage.write(to: sourceURL)

        #expect(!workspace.configureFirmware(from: sourceURL))
        #expect(workspace.errorMessage != nil)
        #expect(workspace.machineSnapshot.loadedSystemROMByteCount == 0)
    }
}
