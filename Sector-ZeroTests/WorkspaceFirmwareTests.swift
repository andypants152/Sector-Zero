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
        #expect(workspace.machineSnapshot.loadedSystemROMByteCount == 64 * 1_024)
        #expect(workspace.currentProject?.metadata.firmwarePath == "firmware/sector-zero-bios-1.0.bin")
        #expect(workspace.machineSnapshot.cpu.fault == nil)

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
        let originalFirmwarePath = workspace.currentProject?.metadata.firmwarePath
        let originalFirmwareByteCount = workspace.machineSnapshot.loadedSystemROMByteCount

        let sourceURL = root.appendingPathComponent("big.bin", isDirectory: false)
        try Data(count: 65 * 1024).write(to: sourceURL)

        #expect(!workspace.configureFirmware(from: sourceURL))
        #expect(workspace.errorMessage != nil)
        #expect(workspace.currentProject?.metadata.firmwarePath == originalFirmwarePath)
        #expect(workspace.machineSnapshot.loadedSystemROMByteCount == originalFirmwareByteCount)
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

    @Test("Configuring a supported disk mounts it, persists it, reopens it, and ejects safely")
    func configureDiskImageLifecycle() throws {
        let defaultsSuite = "SectorZeroTests.ConfigureDisk.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let image = Data(repeating: 0xA5, count: 40 * 1 * 8 * 512)
        let sourceURL = root.appendingPathComponent("boot.img")
        try image.write(to: sourceURL)

        let workspace = SectorZeroWorkspace(userDefaults: userDefaults)
        #expect(workspace.createProject(named: "Disk", in: root))
        #expect(workspace.configureDiskImage(from: sourceURL))
        #expect(workspace.currentProject?.metadata.diskImagePath == "disk/boot.img")
        #expect(workspace.machine.snapshot().floppyController.mediaByteCount == image.count)

        let projectURL = try #require(workspace.currentProject?.projectURL)
        let installedURL = try #require(workspace.currentProject?.configuredDiskImageURL)
        let reopened = SectorZeroWorkspace(userDefaults: userDefaults)
        #expect(reopened.openProject(at: projectURL))
        #expect(reopened.machineSnapshot.floppyController.mediaByteCount == image.count)
        #expect(reopened.machineSnapshot.floppyController.mediaGeometry?.sectorsPerTrack == 8)

        #expect(reopened.ejectDiskImage())
        #expect(reopened.currentProject?.metadata.diskImagePath == nil)
        #expect(reopened.machineSnapshot.floppyController.mediaGeometry == nil)
        #expect(FileManager.default.fileExists(atPath: installedURL.path))
    }

    @Test("An unsupported disk size is rejected before project or media state changes")
    func rejectsUnsupportedDiskImage() throws {
        let defaultsSuite = "SectorZeroTests.RejectDisk.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }
        let root = try makeTemporaryRoot()
        defer { try? FileManager.default.removeItem(at: root) }
        let sourceURL = root.appendingPathComponent("bad.img")
        try Data(repeating: 0xCC, count: 1_024).write(to: sourceURL)

        let workspace = SectorZeroWorkspace(userDefaults: userDefaults)
        #expect(workspace.createProject(named: "Disk", in: root))
        #expect(!workspace.configureDiskImage(from: sourceURL))
        #expect(workspace.errorMessage?.contains("Unsupported floppy image size") == true)
        #expect(workspace.currentProject?.metadata.diskImagePath == nil)
        #expect(workspace.machineSnapshot.floppyController.mediaGeometry == nil)
    }
}
