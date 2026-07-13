import Foundation
import Observation

private final class MachineRunControl: @unchecked Sendable {
    private let lock = NSLock()
    private var pauseRequested = false

    func begin() {
        lock.withLock { pauseRequested = false }
    }

    func requestPause() {
        lock.withLock { pauseRequested = true }
    }

    func shouldPause() -> Bool {
        lock.withLock { pauseRequested }
    }
}

@MainActor
@Observable
final class SectorZeroWorkspace {
    private let recentProjectsKey = "SectorZero.RecentProjects"
    private let maximumRecentProjects = 8

    var currentProject: SectorZeroProject?
    var recentProjects: [RecentProject]
    var errorMessage: String?
    let machine: Machine
    private(set) var machineSnapshot: MachineSnapshot
    private(set) var isRunning = false
    private(set) var lastRunStopReason: MachineRunStopReason?
    private let runControl = MachineRunControl()
    private let executionQueue = DispatchQueue(label: "xyz.andypants.Sector-Zero.machine", qos: .userInitiated)
    private var activeRunID: UUID?
    private let sliceInstructionLimit = 2_048

    init() {
        let machine = Machine()
        self.machine = machine
        self.recentProjects = Self.loadRecentProjects(key: recentProjectsKey)
        self.machineSnapshot = machine.snapshot()
    }

    init(machine: Machine) {
        self.machine = machine
        self.recentProjects = Self.loadRecentProjects(key: recentProjectsKey)
        self.machineSnapshot = machine.snapshot()
    }

    /// Advances the emulated machine by one instruction step and republishes the
    /// resulting state so observing views refresh.
    func step() {
        guard !isRunning else { return }
        machine.step()
        machineSnapshot = machine.snapshot()
    }

    var runButtonTitle: String {
        isRunning ? "PAUSE" : "RUN"
    }

    func toggleRunPause() {
        isRunning ? pause() : run()
    }

    /// Starts background execution in deterministic bounded slices. The main
    /// actor receives exactly one immutable snapshot per completed slice.
    func run() {
        guard !isRunning else { return }
        let runID = UUID()
        activeRunID = runID
        isRunning = true
        lastRunStopReason = nil
        runControl.begin()

        let machine = machine
        let control = runControl
        let sliceLimit = sliceInstructionLimit
        executionQueue.async { [weak self] in
            while true {
                guard self != nil else { return }
                let result = machine.runSlice(maxInstructions: sliceLimit) {
                    control.shouldPause()
                }
                Task { @MainActor [weak self] in
                    self?.publish(result, for: runID)
                }
                switch result.stopReason {
                case .instructionLimit: continue
                default: return
                }
            }
        }
    }

    /// Requests a pause. The execution queue observes it before the next
    /// instruction boundary and publishes that slice's final snapshot.
    func pause() {
        guard isRunning else { return }
        runControl.requestPause()
    }

    func resetMachine() {
        guard !isRunning else { return }
        machine.reset()
        lastRunStopReason = nil
        machineSnapshot = machine.snapshot()
    }

    private func publish(_ result: MachineRunSlice, for runID: UUID) {
        guard activeRunID == runID else { return }
        machineSnapshot = result.snapshot
        guard result.stopReason != .instructionLimit else { return }
        lastRunStopReason = result.stopReason
        isRunning = false
        activeRunID = nil
    }

    var windowTitle: String {
        guard let currentProject else {
            return "Sector Zero"
        }

        return "\(currentProject.projectName) - Sector Zero"
    }

    var statusText: String {
        guard let currentProject else {
            return "No Machine Open"
        }

        return "Machine Open - \(currentProject.projectURL.deletingLastPathComponent().path)"
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

    @discardableResult
    func deleteProject(_ recentProject: RecentProject) -> Bool {
        do {
            try SectorZeroProjectStore.deleteProject(at: recentProject.projectURL)
            if currentProject?.projectURL == recentProject.projectURL {
                currentProject = nil
            }
            forgetProject(at: recentProject.projectURL)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
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

    private func forgetProject(at projectURL: URL) {
        recentProjects.removeAll { $0.projectURL == projectURL }
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
