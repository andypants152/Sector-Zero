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
}

struct ProjectMetadata: Codable, Equatable, Sendable {
    var formatVersion: Int
    var buildSettings: [String: String]
    var userInfo: [String: String]

    init(
        formatVersion: Int = 1,
        buildSettings: [String: String] = [:],
        userInfo: [String: String] = [:]
    ) {
        self.formatVersion = formatVersion
        self.buildSettings = buildSettings
        self.userInfo = userInfo
    }
}

struct RecentProject: Codable, Equatable, Identifiable, Sendable {
    var projectName: String
    var projectURL: URL
    var lastOpenedDate: Date

    var id: URL { projectURL }
}
