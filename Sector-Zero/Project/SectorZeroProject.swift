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

    var configuredFirmwareURL: URL? {
        guard let path = metadata.firmwarePath, !path.isEmpty else { return nil }
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

    init(
        formatVersion: Int = 1,
        buildSettings: [String: String] = [:],
        userInfo: [String: String] = [:],
        firmwarePath: String? = nil
    ) {
        self.formatVersion = formatVersion
        self.buildSettings = buildSettings
        self.userInfo = userInfo
        self.firmwarePath = firmwarePath
    }
}

struct RecentProject: Codable, Equatable, Identifiable, Sendable {
    var projectName: String
    var projectURL: URL
    var lastOpenedDate: Date

    var id: URL { projectURL }
}
