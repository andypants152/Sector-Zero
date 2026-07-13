import Foundation
import Observation

@MainActor
@Observable
final class SectorZeroWorkspace {
    private let recentProjectsKey = "SectorZero.RecentProjects"
    private let maximumRecentProjects = 8

    var currentProject: SectorZeroProject?
    var recentProjects: [RecentProject]
    var errorMessage: String?
    let cpu = CPU8086()

    init() {
        self.recentProjects = Self.loadRecentProjects(key: recentProjectsKey)
    }

    var windowTitle: String {
        guard let currentProject else {
            return "Sector Zero"
        }

        return "\(currentProject.projectName) - Sector Zero"
    }

    var statusText: String {
        guard let currentProject else {
            return "No Project Open"
        }

        return "Project Open - \(currentProject.projectURL.deletingLastPathComponent().path)"
    }

    @discardableResult
    func createProject(named projectName: String, in destinationFolderURL: URL) -> Bool {
        do {
            let project = try SectorZeroProjectStore.createProject(named: projectName, in: destinationFolderURL)
            open(project)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func openProject(at url: URL) -> Bool {
        do {
            let project = try SectorZeroProjectStore.openProject(at: url)
            open(project)
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func openRecentProject(_ recentProject: RecentProject) {
        openProject(at: recentProject.projectURL)
    }

    private func open(_ project: SectorZeroProject) {
        currentProject = project
        errorMessage = nil
        remember(project)
    }

    private func remember(_ project: SectorZeroProject) {
        let recentProject = RecentProject(
            projectName: project.projectName,
            projectURL: project.projectURL,
            lastOpenedDate: project.lastOpenedDate
        )
        recentProjects.removeAll { $0.projectURL == project.projectURL }
        recentProjects.insert(recentProject, at: 0)
        if recentProjects.count > maximumRecentProjects {
            recentProjects.removeLast(recentProjects.count - maximumRecentProjects)
        }
        saveRecentProjects()
    }

    private func saveRecentProjects() {
        guard let data = try? Self.encoder.encode(recentProjects) else {
            return
        }

        UserDefaults.standard.set(data, forKey: recentProjectsKey)
    }

    private static func loadRecentProjects(key: String) -> [RecentProject] {
        guard let data = UserDefaults.standard.data(forKey: key),
              let projects = try? decoder.decode([RecentProject].self, from: data) else {
            return []
        }

        return projects
    }

    private static let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        return encoder
    }()

    private static let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()
}
