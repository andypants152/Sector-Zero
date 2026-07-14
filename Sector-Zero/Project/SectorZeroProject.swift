import Foundation

struct SectorZeroProject: Codable, Equatable, Identifiable, Sendable {
    static let firmwareProvenanceKey = "firmwareProvenance"
    static let builtInFirmwareProvenance = "sector-zero-bios-1.0"
    var projectName: String
    var projectURL: URL
    var creationDate: Date
    var lastOpenedDate: Date
    var sourceFolderURL: URL
    var buildFolderURL: URL
    var diskImageURL: URL
    var metadata: ProjectMetadata

    var id: URL { projectURL }

    var firmwareFolderURL: URL {
        projectURL.appendingPathComponent("firmware", isDirectory: true)
    }

    /// `diskImageURL` remains the package's existing disk-folder URL. The
    /// selected image is recorded separately so format-version-1 projects
    /// continue to decode unchanged.
    var configuredDiskImageURL: URL? {
        resolvedProjectFileURL(metadata.diskImagePath)
    }

    var configuredFloppyBURL: URL? {
        resolvedProjectFileURL(metadata.floppyBPath)
    }

    var configuredHardDiskURL: URL? {
        resolvedProjectFileURL(metadata.hardDiskPath)
    }

    var configuredFirmwareURL: URL? {
        resolvedProjectFileURL(metadata.firmwarePath)
    }

    /// BIOS-specific UI explanations are enabled only for firmware installed
    /// from Sector Zero's bundled image. Older projects intentionally fall
    /// back to generic narration until that image is reinstalled.
    var usesBuiltInFirmware: Bool {
        metadata.userInfo[Self.firmwareProvenanceKey] == Self.builtInFirmwareProvenance
    }

    private func resolvedProjectFileURL(_ configuredPath: String?) -> URL? {
        guard let path = configuredPath, !path.isEmpty else { return nil }
        if path.hasPrefix("/") {
            return URL(fileURLWithPath: path)
        }
        return projectURL.appendingPathComponent(path, isDirectory: false)
    }
}

struct ProjectMetadata: Codable, Equatable, Sendable {
    var formatVersion: Int
    var buildSettings: [String: String]
    var userInfo: [String: String]
    var firmwarePath: String?
    var diskImagePath: String?
    var floppyBPath: String?
    var hardDiskPath: String?

    init(
        formatVersion: Int = 1,
        buildSettings: [String: String] = [:],
        userInfo: [String: String] = [:],
        firmwarePath: String? = nil,
        diskImagePath: String? = nil,
        floppyBPath: String? = nil,
        hardDiskPath: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.buildSettings = buildSettings
        self.userInfo = userInfo
        self.firmwarePath = firmwarePath
        self.diskImagePath = diskImagePath
        self.floppyBPath = floppyBPath
        self.hardDiskPath = hardDiskPath
    }
}

struct RecentProject: Codable, Equatable, Identifiable, Sendable {
    var projectName: String
    var projectURL: URL
    var lastOpenedDate: Date

    var id: URL { projectURL }
}
