import Foundation
import Testing
@testable import Sector_Zero

/// Milestone 41 — PC physical address map, protected ROM, and firmware loading.
struct PCMemoryMapTests {
    @Test("Default map exposes conventional RAM, adapter space, and system ROM")
    func defaultRegions() {
        let snapshot = Machine().snapshot()

        #expect(snapshot.memoryRegions == [
            MemoryRegionSnapshot(name: "Conventional RAM", range: 0x00000...0x9FFFF, kind: .ram),
            MemoryRegionSnapshot(name: "Adapter Space", range: 0xA0000...0xEFFFF, kind: .reserved),
            MemoryRegionSnapshot(name: "System ROM", range: 0xF0000...0xFFFFF, kind: .rom),
        ])
        #expect(snapshot.loadedSystemROMByteCount == 0)
    }

    @Test("Conventional RAM boundaries are writable and adapter space is open bus")
    func regionBoundaries() {
        let bus = EmulatorBus(memory: Memory())

        bus.writeByte(0x12, at: 0x00000)
        bus.writeByte(0x34, at: 0x9FFFF)
        bus.writeByte(0x56, at: 0xA0000)
        bus.writeByte(0x78, at: 0xEFFFF)

        #expect(bus.readByte(at: 0x00000) == 0x12)
        #expect(bus.readByte(at: 0x9FFFF) == 0x34)
        #expect(bus.readByte(at: 0xA0000) == 0xFF)
        #expect(bus.readByte(at: 0xEFFFF) == 0xFF)
        #expect(bus.readByte(at: 0xF0000) == 0xFF)
    }

    @Test("Guest writes to system ROM are rejected and diagnosed")
    func romWriteProtection() throws {
        let bus = EmulatorBus(memory: Memory())
        try bus.loadBytes([0xA5], at: 0xFFFF0)

        bus.writeByte(0x00, at: 0xFFFF0)

        #expect(bus.readByte(at: 0xFFFF0) == 0xA5)
        #expect(bus.lastMemoryMapError == .writeToReadOnly(0xFFFF0))
        #expect(bus.rejectedROMWriteCount == 1)
        bus.clearMemoryMapError()
        #expect(bus.lastMemoryMapError == nil)
    }

    @Test("Firmware is top-aligned over the reset vector and fetched after reset")
    func resetVectorFirmwareFetch() throws {
        let machine = Machine()
        let firmware = Data([0xF4] + Array(repeating: UInt8(0x90), count: 15))

        try machine.loadSystemROM(firmware)
        #expect(machine.snapshot().loadedSystemROMByteCount == 16)
        #expect(machine.bus.readByte(at: 0xFFFF0) == 0xF4)
        #expect(machine.cpu.cs == 0xFFFF)
        #expect(machine.cpu.ip == 0)

        machine.step()
        #expect(machine.cpu.halted)
        #expect(machine.cpu.ip == 1)
    }

    @Test("Word access crosses RAM/adapter and 1 MiB wrap boundaries bytewise")
    func wordBoundaryAccess() throws {
        let bus = EmulatorBus(memory: Memory())
        bus.writeByte(0x34, at: 0x9FFFF)
        #expect(bus.readWord(at: 0x9FFFF) == 0xFF34)

        try bus.loadBytes([0x78], at: 0xFFFFF)
        bus.writeByte(0x56, at: 0x00000)
        #expect(bus.readWord(at: 0xFFFFF) == 0x5678)

        bus.writeWord(0xABCD, at: 0xFFFFF)
        #expect(bus.readByte(at: 0xFFFFF) == 0x78)
        #expect(bus.readByte(at: 0x00000) == 0xAB)
        #expect(bus.lastMemoryMapError == .writeToReadOnly(0xFFFFF))
        #expect(bus.rejectedROMWriteCount == 1)
    }

    @Test("Direct bus addresses preserve 20-bit physical aliasing")
    func physicalAliasing() {
        let bus = EmulatorBus(memory: Memory())
        bus.writeByte(0xCC, at: 0x00010)

        #expect(bus.readByte(at: 0x100010) == 0xCC)
        bus.writeByte(0x55, at: 0x200010)
        #expect(bus.readByte(at: 0x00010) == 0x55)
    }

    @Test("Custom maps reject overlap and addresses beyond 20 bits")
    func overlapRejection() throws {
        let bus = EmulatorBus(memory: Memory(), installPCMemoryMap: false)
        try bus.mapRAM(0x0000...0x0FFF, name: "RAM")

        #expect(throws: MemoryMapError.overlappingRegion(0x0800...0x17FF)) {
            try bus.mapReserved(0x0800...0x17FF, name: "Overlap")
        }
        #expect(throws: MemoryMapError.invalidRange(0xF0000...0x100000)) {
            try bus.mapROM(0xF0000...0x100000, image: [], name: "Too High")
        }
    }

    @Test("Host images cannot populate reserved adapter space")
    func reservedImageRejection() {
        let bus = EmulatorBus(memory: Memory())
        #expect(throws: MemoryMapError.imageTargetsReservedSpace(0xA0000)) {
            try bus.loadBytes([0x01], at: 0xA0000)
        }
    }

    @Test("System ROM rejects empty and oversized firmware")
    func firmwareSizeValidation() {
        let bus = EmulatorBus(memory: Memory())
        #expect(throws: MemoryMapError.imageTooLarge(size: 0, capacity: 65_536)) {
            try bus.loadSystemROM(Data())
        }
        #expect(throws: MemoryMapError.imageTooLarge(size: 65_537, capacity: 65_536)) {
            try bus.loadSystemROM(Data(repeating: 0, count: 65_537))
        }
    }

    @Test("A guest ROM write stops a run slice without inventing a CPU fault")
    func runSliceSurfacesROMViolation() throws {
        let machine = Machine()
        let program: [UInt8] = [
            0xB8, 0x00, 0xF0,       // MOV AX,F000h
            0x8E, 0xD8,             // MOV DS,AX
            0xC6, 0x06, 0xF0, 0xFF, 0x00, // MOV byte [FFF0h],0
        ]
        try machine.bus.loadBytes(program, at: 0xFFFF0)

        let result = machine.runSlice(maxInstructions: 10)

        #expect(result.executedBoundaries == 3)
        #expect(result.stopReason == .memoryMapViolation(.writeToReadOnly(0xFFFF0)))
        #expect(result.snapshot.lastMemoryMapError == .writeToReadOnly(0xFFFF0))
        #expect(result.snapshot.rejectedROMWriteCount == 1)
        #expect(result.snapshot.cpu.fault == nil)
        #expect(machine.bus.readByte(at: 0xFFFF0) == 0xB8)
    }
}

@MainActor
struct ProjectFirmwareTests {
    @Test("Opening a project loads its configured firmware and republishes the snapshot")
    func projectFirmware() throws {
        let defaultsSuite = "SectorZeroTests.ProjectFirmware.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroFirmwareTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try SectorZeroProjectStore.createProject(named: "Firmware", in: root)
        let firmwareURL = project.firmwareFolderURL.appendingPathComponent("bios.bin")
        try Data([0xF4] + Array(repeating: UInt8(0x90), count: 15)).write(to: firmwareURL)
        project.metadata.firmwarePath = "firmware/bios.bin"
        try SectorZeroProjectStore.save(project)

        let workspace = SectorZeroWorkspace(userDefaults: userDefaults)
        #expect(workspace.openProject(at: project.projectURL))
        #expect(workspace.currentProject?.projectName == "Firmware")
        #expect(workspace.machineSnapshot.loadedSystemROMByteCount == 16)
        #expect(workspace.machine.bus.readByte(at: 0xFFFF0) == 0xF4)
    }

    @Test("Missing recent machine packages are pruned from persistent state")
    func staleRecentProjectsArePruned() throws {
        let defaultsSuite = "SectorZeroTests.StaleRecentProjects.\(UUID().uuidString)"
        let userDefaults = try #require(UserDefaults(suiteName: defaultsSuite))
        defer { userDefaults.removePersistentDomain(forName: defaultsSuite) }
        let missingURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("Missing-\(UUID().uuidString).szm", isDirectory: true)
        let recent = RecentProject(
            projectName: "Firmware",
            projectURL: missingURL,
            lastOpenedDate: Date()
        )
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        userDefaults.set(
            try encoder.encode([recent]),
            forKey: "SectorZero.RecentProjects"
        )

        let workspace = SectorZeroWorkspace(userDefaults: userDefaults)

        #expect(workspace.recentProjects.isEmpty)
        let persistedData = try #require(userDefaults.data(forKey: "SectorZero.RecentProjects"))
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        #expect(try decoder.decode([RecentProject].self, from: persistedData).isEmpty)
    }


    @Test("Single-step ROM violations surface through the workspace error channel")
    func workspaceSurfacesROMViolation() throws {
        let machine = Machine()
        try machine.bus.loadBytes([
            0xB8, 0x00, 0xF0,
            0x8E, 0xD8,
            0xC6, 0x06, 0xF0, 0xFF, 0x00,
        ], at: 0xFFFF0)
        let workspace = SectorZeroWorkspace(machine: machine)

        workspace.step()
        workspace.step()
        workspace.step()

        #expect(workspace.machineSnapshot.rejectedROMWriteCount == 1)
        #expect(workspace.errorMessage?.contains("read-only address FFFF0h") == true)
        #expect(workspace.machineSnapshot.cpu.fault == nil)
    }
}
