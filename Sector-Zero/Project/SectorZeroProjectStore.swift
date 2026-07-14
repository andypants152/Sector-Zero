import Foundation

enum ProjectDiskSlot: Equatable, Sendable {
    case floppyA
    case floppyB
    case hardDisk
}

enum SectorZeroProjectStoreError: LocalizedError {
    case emptyProjectName
    case projectAlreadyExists(URL)
    case invalidProjectPackage(URL)

    var errorDescription: String? {
        switch self {
        case .emptyProjectName:
            return "Enter a machine name."
        case .projectAlreadyExists(let url):
            return "A machine already exists at \(url.path)."
        case .invalidProjectPackage(let url):
            return "No Sector Zero machine metadata was found at \(url.path)."
        }
    }
}

enum SectorZeroProjectStore {
    static let packageExtension = "szm"
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
        let firmwareFolderURL = packageURL.appendingPathComponent("firmware", isDirectory: true)
        let now = Date()

        try fileManager.createDirectory(at: packageURL, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: sourceFolderURL, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: buildFolderURL, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: diskFolderURL, withIntermediateDirectories: false)
        try fileManager.createDirectory(at: firmwareFolderURL, withIntermediateDirectories: false)

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
        try FileManager.default.createDirectory(at: project.firmwareFolderURL, withIntermediateDirectories: true)
        try save(project)
        return project
    }

    /// Writes a firmware image into the package's firmware folder, records
    /// the package-relative path in metadata, and persists it. An existing
    /// image with the same name is replaced. Returns the updated project.
    static func installFirmware(
        _ image: Data,
        named rawFileName: String,
        into project: SectorZeroProject,
        isBuiltInFirmware: Bool = false
    ) throws -> SectorZeroProject {
        let fileName = sanitizedFirmwareFileName(for: rawFileName)
        try FileManager.default.createDirectory(
            at: project.firmwareFolderURL,
            withIntermediateDirectories: true
        )
        let destinationURL = project.firmwareFolderURL.appendingPathComponent(fileName, isDirectory: false)
        try image.write(to: destinationURL, options: [.atomic])

        var updated = project
        updated.metadata.firmwarePath = "firmware/\(fileName)"
        if isBuiltInFirmware {
            updated.metadata.userInfo[SectorZeroProject.firmwareProvenanceKey] = SectorZeroProject.builtInFirmwareProvenance
        } else {
            updated.metadata.userInfo.removeValue(forKey: SectorZeroProject.firmwareProvenanceKey)
        }
        try save(updated)
        return updated
    }

    /// Copies a prospective floppy image into the package's disk folder and
    /// records its package-relative location. Geometry and media validation
    /// belong to M47's floppy-media layer; this method only provides atomic
    /// project storage and backward-compatible metadata.
    static func installDiskImage(
        _ image: Data,
        named rawFileName: String,
        into project: SectorZeroProject,
        slot: ProjectDiskSlot = .floppyA
    ) throws -> SectorZeroProject {
        let destinationURL = try storeDiskImage(image, named: rawFileName, into: project, slot: slot)
        let fileName = destinationURL.lastPathComponent

        var updated = project
        switch slot {
        case .floppyA: updated.metadata.diskImagePath = "disk/\(fileName)"
        case .floppyB: updated.metadata.floppyBPath = "disk/\(fileName)"
        case .hardDisk: updated.metadata.hardDiskPath = "disk/\(fileName)"
        }
        try save(updated)
        return updated
    }

    /// Selects an existing package-local image for a drive. Unlike
    /// `installDiskImage`, this never copies or rewrites the media file; it is
    /// the operation used by the media library when the same image is reused.
    static func assignStoredDiskImage(
        at imageURL: URL,
        to project: SectorZeroProject,
        slot: ProjectDiskSlot
    ) throws -> SectorZeroProject {
        let candidateURL = imageURL.standardizedFileURL
        let storeURL = project.diskImageURL.standardizedFileURL
        guard candidateURL.deletingLastPathComponent() == storeURL,
              FileManager.default.fileExists(atPath: candidateURL.path) else {
            throw SectorZeroProjectStoreError.invalidProjectPackage(project.projectURL)
        }

        var updated = project
        let path = "disk/\(candidateURL.lastPathComponent)"
        switch slot {
        case .floppyA: updated.metadata.diskImagePath = path
        case .floppyB: updated.metadata.floppyBPath = path
        case .hardDisk: updated.metadata.hardDiskPath = path
        }
        try save(updated)
        return updated
    }

    /// Copies media into the package without mounting it in a drive.
    @discardableResult
    static func storeDiskImage(
        _ image: Data,
        named rawFileName: String,
        into project: SectorZeroProject,
        slot: ProjectDiskSlot = .floppyA
    ) throws -> URL {
        let fallback = slot == .hardDisk ? "hard-disk.img" : "floppy.img"
        let fileName = sanitizedFileName(for: rawFileName, fallback: fallback)
        try FileManager.default.createDirectory(at: project.diskImageURL, withIntermediateDirectories: true)
        let destinationURL = project.diskImageURL.appendingPathComponent(fileName, isDirectory: false)
        try image.write(to: destinationURL, options: [.atomic])
        return destinationURL
    }

    /// Ejects the configured image without deleting it from the project. This
    /// keeps eject reversible and avoids surprising data loss.
    static func ejectDiskImage(
        from project: SectorZeroProject,
        slot: ProjectDiskSlot = .floppyA
    ) throws -> SectorZeroProject {
        var updated = project
        switch slot {
        case .floppyA: updated.metadata.diskImagePath = nil
        case .floppyB: updated.metadata.floppyBPath = nil
        case .hardDisk: updated.metadata.hardDiskPath = nil
        }
        try save(updated)
        return updated
    }

    /// Returns the images kept in this machine's private media store. Images
    /// are deliberately stored inside the package, rather than referenced at
    /// their original host locations, so a machine remains portable.
    static func storedDiskImages(in project: SectorZeroProject) throws -> [URL] {
        let fileManager = FileManager.default
        try fileManager.createDirectory(at: project.diskImageURL, withIntermediateDirectories: true)
        return try fileManager.contentsOfDirectory(
            at: project.diskImageURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]
        )
        .filter { url in
            var isDirectory: ObjCBool = false
            return fileManager.fileExists(atPath: url.path, isDirectory: &isDirectory) && !isDirectory.boolValue
        }
        .sorted { $0.lastPathComponent.localizedStandardCompare($1.lastPathComponent) == .orderedAscending }
    }

    /// Removes an unmounted copy from the machine's private media store.
    static func removeStoredDiskImage(at imageURL: URL, from project: SectorZeroProject) throws {
        let storeURL = project.diskImageURL.standardizedFileURL.path
        let candidateURL = imageURL.standardizedFileURL
        guard candidateURL.deletingLastPathComponent().path == storeURL else {
            throw SectorZeroProjectStoreError.invalidProjectPackage(project.projectURL)
        }
        try FileManager.default.removeItem(at: candidateURL)
    }

    static func renameProject(_ project: SectorZeroProject, to rawName: String) throws -> SectorZeroProject {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { throw SectorZeroProjectStoreError.emptyProjectName }
        var updated = project
        updated.projectName = name
        try save(updated)
        return updated
    }

    static func save(_ project: SectorZeroProject) throws {
        let metadataURL = project.projectURL.appendingPathComponent(metadataFileName, isDirectory: false)
        let data = try encoder.encode(project)
        try data.write(to: metadataURL, options: [.atomic])
    }

    static func deleteProject(at url: URL) throws {
        let packageURL = normalizedPackageURL(from: url)
        let metadataURL = packageURL.appendingPathComponent(metadataFileName, isDirectory: false)

        guard FileManager.default.fileExists(atPath: metadataURL.path) else {
            throw SectorZeroProjectStoreError.invalidProjectPackage(packageURL)
        }

        try FileManager.default.removeItem(at: packageURL)
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

    private static func sanitizedFirmwareFileName(for rawFileName: String) -> String {
        sanitizedFileName(for: rawFileName, fallback: "firmware.bin")
    }

    private static func sanitizedFileName(for rawFileName: String, fallback: String) -> String {
        let invalidCharacters = CharacterSet(charactersIn: "/:").union(.newlines).union(.controlCharacters)
        let components = rawFileName.components(separatedBy: invalidCharacters)
        let sanitized = components.joined(separator: "-").trimmingCharacters(in: .whitespacesAndNewlines)
        return sanitized.isEmpty ? fallback : sanitized
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
