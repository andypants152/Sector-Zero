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
}
