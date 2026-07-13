import Foundation

struct SectorZeroProject: Codable, Equatable, Identifiable, Sendable {
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

    var configuredFirmwareURL: URL? {
        resolvedProjectFileURL(metadata.firmwarePath)
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

    init(
        formatVersion: Int = 1,
        buildSettings: [String: String] = [:],
        userInfo: [String: String] = [:],
        firmwarePath: String? = nil,
        diskImagePath: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.buildSettings = buildSettings
        self.userInfo = userInfo
        self.firmwarePath = firmwarePath
        self.diskImagePath = diskImagePath
    }
}

struct RecentProject: Codable, Equatable, Identifiable, Sendable {
    var projectName: String
    var projectURL: URL
    var lastOpenedDate: Date

    var id: URL { projectURL }
}
