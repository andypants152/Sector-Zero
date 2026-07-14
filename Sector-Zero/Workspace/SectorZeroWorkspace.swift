import Foundation
import Observation

private final class MachineRunControl: @unchecked Sendable {
    private let lock = NSLock()
    nonisolated(unsafe) private var pauseRequested = false
    nonisolated(unsafe) private var runSpeedCyclesPerSecond: Double?
    nonisolated(unsafe) private var presentationFPS = 60
    nonisolated(unsafe) private var lastPublicationTime: TimeInterval = 0

    nonisolated func begin() {
        lock.withLock {
            pauseRequested = false
            lastPublicationTime = 0
        }
    }

    nonisolated func setRunSpeedCap(_ cap: RunSpeedCap) {
        lock.withLock { runSpeedCyclesPerSecond = cap.cyclesPerSecond }
    }

    nonisolated func setPresentationFPS(_ fps: Int) {
        lock.withLock { presentationFPS = fps }
    }

    nonisolated func currentRunSpeedCyclesPerSecond() -> Double? {
        lock.withLock { runSpeedCyclesPerSecond }
    }

    nonisolated func requestPause() {
        lock.withLock { pauseRequested = true }
    }

    nonisolated func shouldPause() -> Bool {
        lock.withLock { pauseRequested }
    }

    /// Coalesces UI work without slowing the emulated machine. The final
    /// result of a run is always published, regardless of this cadence.
    nonisolated func shouldPublish(at time: TimeInterval) -> Bool {
        lock.withLock {
            let interval = 1.0 / Double(presentationFPS)
            guard time - lastPublicationTime >= interval else { return false }
            lastPublicationTime = time
            return true
        }
    }
}

enum RunSpeedCap: String, CaseIterable, Identifiable, Sendable {
    case khz250
    case khz500
    case mhz1
    case mhz2
    case pcXT
    case unlimited

    nonisolated var id: String { rawValue }

    nonisolated var label: String {
        switch self {
        case .khz250: "250 KHz"
        case .khz500: "500 KHz"
        case .mhz1: "1 MHz"
        case .mhz2: "2 MHz"
        case .pcXT: "4.77 MHz"
        case .unlimited: "Unlimited"
        }
    }

    nonisolated var detailLabel: String {
        switch self {
        case .pcXT: "PC/XT"
        default: label
        }
    }

    nonisolated var cyclesPerSecond: Double? {
        switch self {
        case .khz250: 250_000
        case .khz500: 500_000
        case .mhz1: 1_000_000
        case .mhz2: 2_000_000
        case .pcXT: 4_770_000
        case .unlimited: nil
        }
    }
}

/// The presentation cadence is deliberately independent of emulation speed.
/// Higher settings keep the CRT shader animation smooth without making the
/// virtual CPU run any faster.
enum DisplayRefreshRate: Int, CaseIterable, Identifiable, Sendable {
    case fps30 = 30
    case fps60 = 60
    case fps120 = 120

    nonisolated var id: Int { rawValue }
    nonisolated var label: String { "\(rawValue) Hz" }
}

/// A display-ready summary of the machine's condition, derived from run
/// state, the latest snapshot, and the last stop reason. Views map the
/// severity to a status hue; the label is shown verbatim.
struct MachineCondition: Equatable, Sendable {
    enum Severity: Equatable, Sendable {
        /// Executing instructions right now.
        case live
        /// Idle with nothing notable to report.
        case ready
        /// Stopped on purpose or awaiting something (pause, HLT, WAIT).
        case held
        /// Stopped in error.
        case fault
    }

    let label: String
    let severity: Severity
}

/// Orders snapshots as they cross from the execution queue to the main actor.
/// `Task` scheduling does not guarantee that independently enqueued presentation
/// tasks arrive in the same order as their source slices, so accepting every
/// matching run ID can otherwise make the UI move backward after a terminal
/// snapshot has already been displayed.
struct RunPresentationHandoff {
    private(set) var activeRunID: UUID?
    private var latestSequence = 0

    mutating func begin(runID: UUID) {
        activeRunID = runID
        latestSequence = 0
    }

    mutating func accept(runID: UUID, sequence: Int) -> Bool {
        guard activeRunID == runID, sequence > latestSequence else { return false }
        latestSequence = sequence
        return true
    }

    mutating func finish(runID: UUID) {
        guard activeRunID == runID else { return }
        activeRunID = nil
    }
}

@MainActor
@Observable
final class SectorZeroWorkspace {
    private static let builtInFirmwareResourceName = "sector-zero-bios-1.0"
    private static let builtInFirmwareResourceExtension = "bin"
    private let recentProjectsKey = "SectorZero.RecentProjects"
    private let runSpeedCapKey = "SectorZero.RunSpeedCap"
    private let displayRefreshRateKey = "SectorZero.DisplayRefreshRate"
    private let maximumRecentProjects = 8
    private let userDefaults: UserDefaults

    var currentProject: SectorZeroProject?
    var recentProjects: [RecentProject]
    var errorMessage: String?
    private(set) var pressedScanCodes: Set<UInt8> = []
    let machine: Machine
    private(set) var machineSnapshot: MachineSnapshot
    private(set) var isRunning = false
    private(set) var lastRunStopReason: MachineRunStopReason?
    private(set) var breakpoints: Set<UInt32> = []
    private(set) var instructionTrace: [InstructionTraceEntry] = []
    var runSpeedCap: RunSpeedCap = .pcXT {
        didSet {
            runControl.setRunSpeedCap(runSpeedCap)
            userDefaults.set(runSpeedCap.rawValue, forKey: runSpeedCapKey)
        }
    }
    var displayRefreshRate: DisplayRefreshRate = .fps60 {
        didSet {
            runControl.setPresentationFPS(displayRefreshRate.rawValue)
            userDefaults.set(displayRefreshRate.rawValue, forKey: displayRefreshRateKey)
        }
    }
    private let runControl = MachineRunControl()
    private let executionQueue = DispatchQueue(label: "xyz.andypants.Sector-Zero.machine", qos: .userInitiated)
    private var presentationHandoff = RunPresentationHandoff()
    private let sliceInstructionLimit = 2_048
    private let sliceClockLimit: UInt64 = 100_000

    init(userDefaults: UserDefaults = .standard) {
        let machine = Machine()
        self.machine = machine
        self.userDefaults = userDefaults
        self.recentProjects = Self.loadRecentProjects(key: recentProjectsKey, from: userDefaults)
        self.runSpeedCap = Self.loadRunSpeedCap(key: runSpeedCapKey, from: userDefaults)
        self.displayRefreshRate = Self.loadDisplayRefreshRate(key: displayRefreshRateKey, from: userDefaults)
        self.machineSnapshot = machine.snapshot()
        self.runControl.setRunSpeedCap(runSpeedCap)
        self.runControl.setPresentationFPS(displayRefreshRate.rawValue)
    }

    init(machine: Machine, userDefaults: UserDefaults = .standard) {
        self.machine = machine
        self.userDefaults = userDefaults
        self.recentProjects = Self.loadRecentProjects(key: recentProjectsKey, from: userDefaults)
        self.runSpeedCap = Self.loadRunSpeedCap(key: runSpeedCapKey, from: userDefaults)
        self.displayRefreshRate = Self.loadDisplayRefreshRate(key: displayRefreshRateKey, from: userDefaults)
        self.machineSnapshot = machine.snapshot()
        self.runControl.setRunSpeedCap(runSpeedCap)
        self.runControl.setPresentationFPS(displayRefreshRate.rawValue)
    }

    /// Advances the emulated machine by one instruction step and republishes the
    /// resulting state so observing views refresh.
    func step() {
        guard !isRunning else { return }
        machine.step()
        apply(machine.snapshot())
    }

    var runButtonTitle: String {
        isRunning ? "PAUSE" : "RUN"
    }

    /// A fault always wins over the halted flag it sets alongside itself, so
    /// an unsupported opcode reads FAULT rather than HALT.
    var machineCondition: MachineCondition {
        if isRunning {
            return MachineCondition(label: "RUNNING", severity: .live)
        }
        if machineSnapshot.cpu.fault != nil {
            return MachineCondition(label: "FAULT", severity: .fault)
        }
        if case .memoryMapViolation = lastRunStopReason {
            return MachineCondition(label: "FAULT", severity: .fault)
        }
        if machineSnapshot.cpu.halted {
            return MachineCondition(label: "HALT", severity: .held)
        }
        if machineSnapshot.cpu.waitingForCoprocessor {
            return MachineCondition(label: "WAIT", severity: .held)
        }
        if lastRunStopReason == .paused {
            return MachineCondition(label: "PAUSED", severity: .held)
        }
        if case .breakpoint = lastRunStopReason {
            return MachineCondition(label: "BREAK", severity: .held)
        }
        if machineSnapshot.loadedSystemROMByteCount == 0 {
            return MachineCondition(label: "NO ROM", severity: .held)
        }
        return MachineCondition(label: "READY", severity: .ready)
    }

    /// One line explaining why the machine is not simply ready, or nil when
    /// there is nothing to report. Faults are described from the snapshot so
    /// a single STEP into a fault is explained the same way as a full run.
    var machineConditionDetail: String? {
        if let fault = machineSnapshot.cpu.fault {
            return "Fault: \(Self.describe(fault))"
        }
        switch lastRunStopReason {
        case .breakpoint(let address):
            return String(format: "Breakpoint at %05Xh", address)
        case .paused:
            return "Paused at instruction boundary"
        case .halted:
            return "CPU halted"
        case .waitingForCoprocessor:
            return "Waiting for coprocessor"
        case .memoryMapViolation:
            return "Stopped by memory map violation"
        case .fault(let fault):
            return "Fault: \(Self.describe(fault))"
        case .instructionLimit, nil:
            if machineSnapshot.loadedSystemROMByteCount == 0 {
                return "No firmware loaded — the machine has nothing to execute"
            }
            return nil
        }
    }

    private static func describe(_ fault: CPUFault) -> String {
        switch fault {
        case .divideError:
            return "divide error"
        case .unsupportedOpcode(let opcode):
            return String(format: "unsupported opcode %02X", opcode)
        case .invalidLockPrefix:
            return "invalid LOCK prefix"
        }
    }

    func toggleRunPause() {
        isRunning ? pause() : run()
    }

    /// Starts background execution in deterministic bounded slices. The main
    /// actor receives exactly one immutable snapshot per completed slice.
    func run() {
        guard !isRunning else { return }
        let runID = UUID()
        presentationHandoff.begin(runID: runID)
        isRunning = true
        lastRunStopReason = nil
        instructionTrace.removeAll(keepingCapacity: true)
        runControl.begin()

        let machine = machine
        let control = runControl
        let sliceLimit = sliceInstructionLimit
        let clockLimit = sliceClockLimit
        let breakpoints = breakpoints
        executionQueue.async { [weak self] in
            var presentationSequence = 0
            while true {
                guard self != nil else { return }
                let sliceStart = Date.timeIntervalSinceReferenceDate
                let result = machine.runSlice(
                    maxInstructions: sliceLimit,
                    maxClocks: clockLimit,
                    breakpoints: breakpoints,
                    traceLimit: 0,
                    haltPolicy: .advanceToInterrupt
                ) {
                    control.shouldPause()
                }
                Self.throttle(result.elapsedClocks, startedAt: sliceStart, control: control)
                switch result.stopReason {
                case .instructionLimit:
                    let now = Date.timeIntervalSinceReferenceDate
                    if control.shouldPublish(at: now) {
                        presentationSequence += 1
                        let sequence = presentationSequence
                        Task { @MainActor [weak self] in
                            self?.publish(result, for: runID, sequence: sequence)
                        }
                    }
                default:
                    presentationSequence += 1
                    let sequence = presentationSequence
                    Task { @MainActor [weak self] in
                        self?.publish(result, for: runID, sequence: sequence)
                    }
                    return
                }
            }
        }
    }

    private nonisolated static func throttle(
        _ elapsedClocks: UInt64,
        startedAt sliceStart: TimeInterval,
        control: MachineRunControl
    ) {
        guard elapsedClocks > 0,
              let cyclesPerSecond = control.currentRunSpeedCyclesPerSecond(),
              cyclesPerSecond > 0 else {
            return
        }

        let deadline = sliceStart + Double(elapsedClocks) / cyclesPerSecond
        let pausePollInterval: TimeInterval = 0.01
        while !control.shouldPause() {
            let remaining = deadline - Date.timeIntervalSinceReferenceDate
            guard remaining > 0 else { return }
            Thread.sleep(forTimeInterval: min(remaining, pausePollInterval))
        }
    }

    /// Requests a pause. The execution queue observes it before the next
    /// instruction boundary and publishes that slice's final snapshot.
    func pause() {
        guard isRunning else { return }
        runControl.requestPause()
    }

    /// Executes at most `maxInstructions` synchronously, respecting configured
    /// breakpoints and publishing both the final snapshot and deterministic trace.
    @discardableResult
    func runBounded(maxInstructions: Int) -> MachineRunSlice? {
        guard !isRunning, maxInstructions >= 0 else { return nil }
        let result = machine.runSlice(
            maxInstructions: maxInstructions,
            breakpoints: breakpoints,
            traceLimit: maxInstructions,
            haltPolicy: .advanceToInterrupt
        )
        instructionTrace = result.trace
        lastRunStopReason = result.stopReason
        apply(result.snapshot)
        return result
    }

    func toggleBreakpoint(at physicalAddress: UInt32) {
        guard physicalAddress < UInt32(Memory.addressableSize) else { return }
        if !breakpoints.insert(physicalAddress).inserted {
            breakpoints.remove(physicalAddress)
        }
    }

    func toggleBreakpointAtCurrentAddress() {
        toggleBreakpoint(at: machineSnapshot.physicalCodeAddress)
    }

    var hasBreakpointAtCurrentAddress: Bool {
        breakpoints.contains(machineSnapshot.physicalCodeAddress)
    }

    func inspectMemory(at physicalAddress: UInt32, byteCount: Int) throws -> [UInt8] {
        guard !isRunning else { return [] }
        return try machine.inspectMemory(at: physicalAddress, byteCount: byteCount)
    }

    var exportedInstructionTrace: String {
        MachineDebugger.exportTrace(instructionTrace)
    }

    func resetMachine() {
        guard !isRunning else { return }
        machine.reset()
        lastRunStopReason = nil
        instructionTrace.removeAll(keepingCapacity: true)
        apply(machine.snapshot())
    }

    /// Translates one host key transition into XT scan codes and posts them
    /// to the machine. Typematic repeats forward extra make codes, matching
    /// the XT keyboard's own repeat stream. Unmapped keys are ignored.
    func handleHostKey(down: Bool, keyCode: UInt16, isRepeat: Bool = false) {
        guard let makeCode = PCKeyMap.makeCode(forMacKeyCode: keyCode) else { return }
        pressXTKey(makeCode, down: down)
    }

    /// Posts one XT key transition to the machine by make code. Shared by the
    /// macOS hardware keyboard (`handleHostKey`) and the iOS on-screen
    /// keyboard. Only keys this workspace pressed emit a break code, so the up
    /// half of a filtered host chord (⌘R) never leaks into the guest.
    func pressXTKey(_ makeCode: UInt8, down: Bool) {
        if down {
            pressedScanCodes.insert(makeCode)
            machine.postScanCode(makeCode)
        } else {
            guard pressedScanCodes.remove(makeCode) != nil else { return }
            machine.postScanCode(makeCode | 0x80)
        }
        deliverHostInputIfIdle()
    }

    /// Releases every held key — called on focus loss so the machine never
    /// sees a key stuck down. Break codes go out lowest-first so the stream
    /// is deterministic.
    func releaseAllHostKeys() {
        guard !pressedScanCodes.isEmpty else { return }
        for makeCode in pressedScanCodes.sorted() {
            machine.postScanCode(makeCode | 0x80)
        }
        pressedScanCodes.removeAll()
        deliverHostInputIfIdle()
    }

    /// While the machine is idle the main actor is its only executor, so
    /// posted codes are delivered immediately and the snapshot republished;
    /// while running, the execution queue drains them at boundaries.
    private func deliverHostInputIfIdle() {
        guard !isRunning else { return }
        machine.drainHostInput()
        apply(machine.snapshot())
    }

    /// Validates and loads a firmware image, installs it into the current
    /// machine package, and resets to power-on state so the new ROM's reset
    /// vector is what runs next. Validation happens before anything is
    /// persisted, so a rejected image leaves the package untouched.
    @discardableResult
    func configureFirmware(from sourceURL: URL, isBuiltInFirmware: Bool = false) -> Bool {
        guard !isRunning else { return false }
        guard let project = currentProject else {
            errorMessage = "Open a machine before choosing firmware."
            return false
        }
        do {
            let image = try Data(contentsOf: sourceURL)
            try machine.loadSystemROM(image)
            machine.reset()
            currentProject = try SectorZeroProjectStore.installFirmware(
                image,
                named: sourceURL.lastPathComponent,
                into: project,
                isBuiltInFirmware: isBuiltInFirmware
            )
            lastRunStopReason = nil
            apply(machine.snapshot())
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func installBuiltInFirmware() -> Bool {
        guard let sourceURL = Bundle.main.url(
            forResource: Self.builtInFirmwareResourceName,
            withExtension: Self.builtInFirmwareResourceExtension
        ) else {
            errorMessage = "The built-in Sector Zero BIOS is missing from this app build."
            return false
        }
        return configureFirmware(from: sourceURL, isBuiltInFirmware: true)
    }

    /// Validates and installs a disk-image copy into the open project, then
    /// mounts the same bytes in the floppy controller without resetting the CPU.
    @discardableResult
    func configureDiskImage(from sourceURL: URL) -> Bool {
        configureFloppyDisk(from: sourceURL, drive: 0)
    }

    @discardableResult
    func configureFloppyDisk(from sourceURL: URL, drive: UInt8) -> Bool {
        guard !isRunning else { return false }
        guard drive < 2 else { return false }
        guard let project = currentProject else {
            errorMessage = "Open a machine before choosing a disk image."
            return false
        }
        do {
            let image = try Data(contentsOf: sourceURL)
            _ = try FloppyDiskGeometry.detect(byteCount: image.count)
            let updatedProject = try SectorZeroProjectStore.installDiskImage(
                image,
                named: sourceURL.lastPathComponent,
                into: project,
                slot: drive == 0 ? .floppyA : .floppyB
            )
            let mountedURL = drive == 0
                ? updatedProject.configuredDiskImageURL
                : updatedProject.configuredFloppyBURL
            try machine.mountFloppyDisk(image, drive: drive, fileURL: mountedURL)
            currentProject = updatedProject
            apply(machine.snapshot())
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Mounts a previously imported image without copying it again. This keeps
    /// the media library authoritative and makes one package-local image
    /// reusable in either floppy drive.
    @discardableResult
    func mountStoredFloppyDisk(at imageURL: URL, drive: UInt8) -> Bool {
        guard !isRunning, drive < 2, let project = currentProject else { return false }
        do {
            let image = try Data(contentsOf: imageURL)
            _ = try FloppyDiskGeometry.detect(byteCount: image.count)
            let updatedProject = try SectorZeroProjectStore.assignStoredDiskImage(
                at: imageURL, to: project, slot: drive == 0 ? .floppyA : .floppyB
            )
            let mountedURL = drive == 0
                ? updatedProject.configuredDiskImageURL
                : updatedProject.configuredFloppyBURL
            try machine.mountFloppyDisk(image, drive: drive, fileURL: mountedURL)
            currentProject = updatedProject
            apply(machine.snapshot())
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Adds a floppy to the package media store without changing either drive.
    @discardableResult
    func importFloppyToStore(from sourceURL: URL) -> Bool {
        guard !isRunning, let project = currentProject else { return false }
        do {
            let image = try Data(contentsOf: sourceURL)
            _ = try FloppyDiskGeometry.detect(byteCount: image.count)
            _ = try SectorZeroProjectStore.storeDiskImage(
                image, named: sourceURL.lastPathComponent, into: project
            )
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    /// Clears the mounted-image selection without deleting the package copy.
    @discardableResult
    func ejectDiskImage() -> Bool {
        ejectFloppyDisk(drive: 0)
    }

    @discardableResult
    func ejectFloppyDisk(drive: UInt8) -> Bool {
        guard !isRunning else { return false }
        guard drive < 2 else { return false }
        guard let project = currentProject else {
            errorMessage = "Open a machine before ejecting its disk image."
            return false
        }
        do {
            let updatedProject = try SectorZeroProjectStore.ejectDiskImage(
                from: project,
                slot: drive == 0 ? .floppyA : .floppyB
            )
            machine.ejectFloppyDisk(drive: drive)
            currentProject = updatedProject
            apply(machine.snapshot())
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func configureHardDisk(from sourceURL: URL) -> Bool {
        guard !isRunning else { return false }
        guard let project = currentProject else {
            errorMessage = "Open a machine before choosing a hard disk image."
            return false
        }
        do {
            let image = try Data(contentsOf: sourceURL)
            _ = try FixedDiskGeometry.detect(byteCount: image.count)
            let updatedProject = try SectorZeroProjectStore.installDiskImage(
                image,
                named: sourceURL.lastPathComponent,
                into: project,
                slot: .hardDisk
            )
            try machine.mountHardDisk(image, fileURL: updatedProject.configuredHardDiskURL)
            currentProject = updatedProject
            apply(machine.snapshot())
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func createBlankHardDisk() -> Bool {
        let temporaryURL = FileManager.default.temporaryDirectory
            .appendingPathComponent("sector-zero-20mb-\(UUID().uuidString).img")
        do {
            try Data(count: FixedDiskGeometry.classic20MB.byteCount).write(to: temporaryURL)
            defer { try? FileManager.default.removeItem(at: temporaryURL) }
            return configureHardDisk(from: temporaryURL)
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func ejectHardDisk() -> Bool {
        guard !isRunning else { return false }
        guard let project = currentProject else { return false }
        do {
            currentProject = try SectorZeroProjectStore.ejectDiskImage(from: project, slot: .hardDisk)
            machine.ejectHardDisk()
            apply(machine.snapshot())
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func renameCurrentProject(to name: String) -> Bool {
        guard !isRunning, let project = currentProject else { return false }
        do {
            currentProject = try SectorZeroProjectStore.renameProject(project, to: name)
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    func storedDiskImages() -> [URL] {
        guard let project = currentProject else { return [] }
        do {
            return try SectorZeroProjectStore.storedDiskImages(in: project)
        } catch {
            errorMessage = error.localizedDescription
            return []
        }
    }

    @discardableResult
    func removeStoredDiskImage(at imageURL: URL) -> Bool {
        guard !isRunning, let project = currentProject else { return false }
        do {
            let standardURL = imageURL.standardizedFileURL
            var updatedProject = project
            if project.configuredDiskImageURL?.standardizedFileURL == standardURL {
                updatedProject = try SectorZeroProjectStore.ejectDiskImage(from: updatedProject, slot: .floppyA)
                machine.ejectFloppyDisk(drive: 0)
            }
            if project.configuredFloppyBURL?.standardizedFileURL == standardURL {
                updatedProject = try SectorZeroProjectStore.ejectDiskImage(from: updatedProject, slot: .floppyB)
                machine.ejectFloppyDisk(drive: 1)
            }
            if project.configuredHardDiskURL?.standardizedFileURL == standardURL {
                updatedProject = try SectorZeroProjectStore.ejectDiskImage(from: updatedProject, slot: .hardDisk)
                machine.ejectHardDisk()
            }
            // Persist all possible ejections above before removing the file.
            try SectorZeroProjectStore.removeStoredDiskImage(at: imageURL, from: updatedProject)
            currentProject = updatedProject
            apply(machine.snapshot())
            errorMessage = nil
            return true
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    private func publish(_ result: MachineRunSlice, for runID: UUID, sequence: Int) {
        guard presentationHandoff.accept(runID: runID, sequence: sequence) else { return }
        apply(result.snapshot)
        instructionTrace.append(contentsOf: result.trace)
        if instructionTrace.count > 4_096 {
            instructionTrace.removeFirst(instructionTrace.count - 4_096)
        }
        guard result.stopReason != .instructionLimit else { return }
        lastRunStopReason = result.stopReason
        isRunning = false
        presentationHandoff.finish(runID: runID)
    }

    private func apply(_ snapshot: MachineSnapshot) {
        machineSnapshot = snapshot
        if let violation = snapshot.lastMemoryMapError {
            errorMessage = violation.localizedDescription
        }
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
            guard open(project) else { return false }
            return installBuiltInFirmware()
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
    }

    @discardableResult
    func openProject(at url: URL) -> Bool {
        do {
            let project = try SectorZeroProjectStore.openProject(at: url)
            return open(project)
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

    @discardableResult
    private func open(_ project: SectorZeroProject) -> Bool {
        do {
            if let firmwareURL = project.configuredFirmwareURL {
                try machine.loadSystemROM(Data(contentsOf: firmwareURL))
            } else {
                machine.clearSystemROM()
            }
            if let diskImageURL = project.configuredDiskImageURL {
                try machine.mountFloppyDisk(Data(contentsOf: diskImageURL), drive: 0, fileURL: diskImageURL)
            } else {
                machine.ejectFloppyDisk(drive: 0)
            }
            if let floppyBURL = project.configuredFloppyBURL {
                try machine.mountFloppyDisk(Data(contentsOf: floppyBURL), drive: 1, fileURL: floppyBURL)
            } else {
                machine.ejectFloppyDisk(drive: 1)
            }
            if let hardDiskURL = project.configuredHardDiskURL {
                try machine.mountHardDisk(Data(contentsOf: hardDiskURL), fileURL: hardDiskURL)
            } else {
                machine.ejectHardDisk()
            }
            apply(machine.snapshot())
        } catch {
            errorMessage = error.localizedDescription
            return false
        }
        currentProject = project
        errorMessage = nil
        remember(project)
        return true
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

        userDefaults.set(data, forKey: recentProjectsKey)
    }

    private static func loadRecentProjects(key: String, from userDefaults: UserDefaults) -> [RecentProject] {
        guard let data = userDefaults.data(forKey: key),
              let projects = try? decoder.decode([RecentProject].self, from: data) else {
            return []
        }

        let existingProjects = projects.filter { project in
            let metadataURL = project.projectURL
                .appendingPathComponent(SectorZeroProjectStore.metadataFileName, isDirectory: false)
            return FileManager.default.fileExists(atPath: metadataURL.path)
        }
        if existingProjects.count != projects.count,
           let data = try? encoder.encode(existingProjects) {
            userDefaults.set(data, forKey: key)
        }
        return existingProjects
    }

    private static func loadRunSpeedCap(key: String, from userDefaults: UserDefaults) -> RunSpeedCap {
        guard let rawValue = userDefaults.string(forKey: key),
              let cap = RunSpeedCap(rawValue: rawValue) else {
            return .pcXT
        }

        return cap
    }

    private static func loadDisplayRefreshRate(key: String, from userDefaults: UserDefaults) -> DisplayRefreshRate {
        guard let rawValue = userDefaults.object(forKey: key) as? Int,
              let rate = DisplayRefreshRate(rawValue: rawValue) else {
            return .fps60
        }
        return rate
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
