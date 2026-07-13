import Foundation

enum SectorZeroProjectStoreError: LocalizedError {
    case emptyProjectName
    case projectAlreadyExists(URL)
    case invalidProjectPackage(URL)

    var errorDescription: String? {
        switch self {
        case .emptyProjectName:
            return "Enter a project name."
        case .projectAlreadyExists(let url):
            return "A project already exists at \(url.path)."
        case .invalidProjectPackage(let url):
            return "No Sector Zero project metadata was found at \(url.path)."
        }
    }
}

enum SectorZeroProjectStore {
    static let packageExtension = "szproj"
    static let metadataFileName = "sectorzero.json"

    static func createProject(named rawName: String, in destinationFolderURL: URL) throws -> SectorZeroProject {
        let projectName = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !projectName.isEmpty else {
            throw SectorZeroProjectStoreError.emptyProjectName
        }

        let packageURL = destinationFolderURL
            .appendingPathComponent(sanitizedPackageName(for: projectName), isDirectory: true)
            .appendingPathExtension(packageExtension)

        let fileManager = FileManager.default
        guard !fileManager.fileExists(atPath: packageURL.path) else {
            throw SectorZeroProjectStoreError.projectAlreadyExists(packageURL)
        }

        let sourceFolderURL = packageURL.appendingPathComponent("src", isDirectory: true)
        let buildFolderURL = packageURL.appendingPathComponent("build", isDirectory: true)
        let diskFolderURL = packageURL.appendingPathComponent("disk", isDirectory: true)
        let now = Date()

        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: sourceFolderURL, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: buildFolderURL, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: diskFolderURL, withIntermediateDirectories: false)

        let project = SectorZeroProject(
            projectName: projectName,
            projectURL: packageURL,
            creationDate: now,
            lastOpenedDate: now,
            sourceFolderURL: sourceFolderURL,
            buildFolderURL: buildFolderURL,
            diskImageURL: diskFolderURL,
            metadata: ProjectMetadata()
        )
        try save(project)
        return project
    }

    static func openProject(at url: URL) throws -> SectorZeroProject {
        let packageURL = normalizedPackageURL(from: url)
        let metadataURL = packageURL.appendingPathComponent(metadataFileName, isDirectory: false)

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw SectorZeroProjectStoreError.invalidProjectPackage(packageURL)
        }

        let data = try Data(contentsOf: metadataURL)
        var project = try decoder.decode(SectorZeroProject.self, from: data)
        project.projectURL = packageURL
        project.sourceFolderURL = packageURL.appendingPathComponent("src", isDirectory: true)
        project.buildFolderURL = packageURL.appendingPathComponent("build", isDirectory: true)
        project.diskImageURL = packageURL.appendingPathComponent("disk", isDirectory: true)
        project.lastOpenedDate = Date()
        try save(project)
        return project
    }

    static func save(_ project: SectorZeroProject) throws {
        let metadataURL = project.projectURL.appendingPathComponent(metadataFileName, isDirectory: false)
        let data = try encoder.encode(project)
        try data.write(to: metadataURL, options: [.atomic])
    }

    private static func normalizedPackageURL(from url: URL) -> URL {
        if url.pathExtension == packageExtension {
            return url
        }

        return url.appendingPathExtension(packageExtension)
    }

    private static func sanitizedPackageName(for projectName: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:").union(.newlines).union(.controlCharacters)
        let components = projectName.components(separatedBy: invalidCharacters)
        let sanitized = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? "Untitled" : sanitized
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
