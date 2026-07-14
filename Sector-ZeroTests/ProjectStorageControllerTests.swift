import Foundation
import Testing
@testable import Sector_Zero

@MainActor
struct ProjectStorageControllerTests {
    @Test("Project packages persist independent A, B, and C image selections")
    func independentSlots() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroStorage-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        var project = try SectorZeroProjectStore.createProject(named: "Storage", in: root)
        project = try SectorZeroProjectStore.installDiskImage(
            Data(repeating: 0xA0, count: 16), named: "a.img", into: project, slot: .floppyA
        )
        project = try SectorZeroProjectStore.installDiskImage(
            Data(repeating: 0xB0, count: 16), named: "b.img", into: project, slot: .floppyB
        )
        project = try SectorZeroProjectStore.installDiskImage(
            Data(repeating: 0xC0, count: 16), named: "c.img", into: project, slot: .hardDisk
        )

        let reopened = try SectorZeroProjectStore.openProject(at: project.projectURL)
        #expect(reopened.configuredDiskImageURL?.lastPathComponent == "a.img")
        #expect(reopened.configuredFloppyBURL?.lastPathComponent == "b.img")
        #expect(reopened.configuredHardDiskURL?.lastPathComponent == "c.img")

        let withoutB = try SectorZeroProjectStore.ejectDiskImage(from: reopened, slot: .floppyB)
        #expect(withoutB.configuredDiskImageURL != nil)
        #expect(withoutB.configuredFloppyBURL == nil)
        #expect(withoutB.configuredHardDiskURL != nil)
    }

    @Test("Stored floppy media does not change a drive selection")
    func storeOnlyMediaIsUnconfigured() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroMediaStore-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try SectorZeroProjectStore.createProject(named: "Media", in: root)
        let stored = try SectorZeroProjectStore.storeDiskImage(
            Data(repeating: 0, count: 1_474_560), named: "dos.img", into: project
        )

        #expect(project.configuredDiskImageURL == nil)
        #expect(try SectorZeroProjectStore.storedDiskImages(in: project).map(\.lastPathComponent) == [stored.lastPathComponent])
    }

    @Test("A stored image can be assigned to a drive without rewriting its package copy")
    func assignStoredMedia() throws {
        let root = FileManager.default.temporaryDirectory
            .appendingPathComponent("SectorZeroStoredAssignment-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let project = try SectorZeroProjectStore.createProject(named: "Media", in: root)
        let image = try SectorZeroProjectStore.storeDiskImage(
            Data(repeating: 0x5A, count: 1_474_560), named: "reuse.img", into: project
        )
        let timestamp = try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate

        let assigned = try SectorZeroProjectStore.assignStoredDiskImage(at: image, to: project, slot: .floppyB)

        #expect(assigned.configuredFloppyBURL == image)
        #expect(try image.resourceValues(forKeys: [.contentModificationDateKey]).contentModificationDate == timestamp)
    }
}
