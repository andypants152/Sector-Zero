import Foundation
import Testing
@testable import Sector_Zero

@MainActor
struct WorkspaceRunTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func workspaceWithBytes(_ bytes: [UInt8]) -> SectorZeroWorkspace {
        let machine = Machine()
        try! machine.bus.loadBytes(bytes, at: resetVector)
        return SectorZeroWorkspace(machine: machine)
    }

    private func isolatedDefaults() -> UserDefaults {
        let suiteName = "SectorZeroWorkspaceRunTests.\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: suiteName)!
        defaults.removePersistentDomain(forName: suiteName)
        return defaults
    }

    /// Generous by design: these waits observe state published through the
    /// main actor, which parallel suite load can delay. Promptness is
    /// asserted separately, measured off the main actor.
    private func waitUntil(
        timeoutNanoseconds: UInt64 = 10_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
    }

    @Test("Presentation handoff rejects out-of-order and completed run slices")
    func presentationHandoffIsMonotonic() {
        var handoff = RunPresentationHandoff()
        let runID = UUID()
        let nextRunID = UUID()

        handoff.begin(runID: runID)
        let acceptsNewerSlice = handoff.accept(runID: runID, sequence: 2)
        let rejectsOlderSlice = handoff.accept(runID: runID, sequence: 1)
        let rejectsOtherRun = handoff.accept(runID: nextRunID, sequence: 3)
        #expect(acceptsNewerSlice)
        #expect(!rejectsOlderSlice)
        #expect(!rejectsOtherRun)

        handoff.finish(runID: runID)
        let rejectsCompletedRun = handoff.accept(runID: runID, sequence: 3)
        #expect(!rejectsCompletedRun)
    }

    @Test("RUN publishes a terminal slice snapshot and returns to idle")
    func runToHalt() async {
        let workspace = workspaceWithBytes([0x90, 0xF4])

        workspace.run()
        #expect(workspace.isRunning)
        #expect(workspace.runButtonTitle == "PAUSE")
        #expect(await waitUntil { !workspace.isRunning })

        #expect(workspace.runButtonTitle == "RUN")
        #expect(workspace.lastRunStopReason == .halted)
        #expect(workspace.machineSnapshot.cpu.halted)
        #expect(workspace.machineSnapshot.cpu.ip == 2)
        #expect(workspace.machineSnapshot.cycleCount == 5)
    }

    @Test("PAUSE stops an unbounded program at an instruction boundary")
    func pause() async {
        let workspace = workspaceWithBytes([0xEB, 0xFE]) // JMP short to self

        workspace.toggleRunPause()
        #expect(await waitUntil { workspace.machineSnapshot.cycleCount > 0 })
        workspace.toggleRunPause()
        #expect(await waitUntil { !workspace.isRunning })

        #expect(workspace.lastRunStopReason == .paused)
        #expect(workspace.runButtonTitle == "RUN")
        #expect(workspace.machineSnapshot.cpu.ip == 0)
        #expect(workspace.machineSnapshot.cycleCount > 0)
    }

    @Test("PAUSE interrupts a pending speed-cap wait")
    func pauseInterruptsThrottle() async {
        // AAM (83 clocks) plus the short jump (15 clocks) makes each 2,048
        // instruction slice take about 0.4 seconds at 250 KHz.
        let workspace = workspaceWithBytes([0xD4, 0x0A, 0xEB, 0xFC])
        workspace.runSpeedCap = .khz250

        workspace.run()
        try? await Task.sleep(nanoseconds: 50_000_000)
        workspace.pause()

        // The run loop delivers the terminal stop reason on its own execution
        // queue. Delivery is guaranteed, so this assertion is deterministic.
        // Promptness of the speed-cap wait itself is asserted off the main
        // actor in `throttleHonorsPendingPause`, where no cross-thread hop
        // falls inside the measured span.
        #expect(await Self.runStopReason(control: workspace.runControl) == .paused)

        #expect(await waitUntil { !workspace.isRunning })
        #expect(workspace.lastRunStopReason == .paused)
    }

    /// Awaits the run's terminal stop reason off the main actor so the
    /// delivery hop does not block the main thread under parallel suite load.
    private nonisolated static func runStopReason(
        control: MachineRunControl
    ) async -> MachineRunStopReason? {
        await control.terminalStopReason()
    }

    @Test("The speed-cap throttle exits immediately when a pause is already pending")
    func throttleHonorsPendingPause() async {
        // A 100_000-clock slice at 250 KHz leaves 0.4 seconds on the throttle
        // deadline. With a pause already pending, the poll loop must exit on
        // its first check instead of sleeping toward the deadline.
        let elapsed = await Self.throttleElapsed(cap: .khz250, pausePending: true)
        #expect(elapsed < 0.1)
    }

    @Test("The speed-cap throttle spends the full slice when no pause is pending")
    func throttleWaitsFullDeadline() async {
        // The same slice at PC/XT speed costs about 21 ms of host time. Without
        // a pause the throttle must actually spend that time, keeping the
        // machine at or below the configured speed.
        let elapsed = await Self.throttleElapsed(cap: .pcXT, pausePending: false)
        #expect(elapsed >= 0.015)
        #expect(elapsed < 1.0)
    }

    /// Runs the speed-cap throttle off the main actor and times only the
    /// throttle call itself, so host scheduling of the surrounding hops does
    /// not contaminate the measurement.
    private nonisolated static func throttleElapsed(
        cap: RunSpeedCap,
        pausePending: Bool
    ) async -> TimeInterval {
        let control = MachineRunControl()
        control.setRunSpeedCap(cap)
        if pausePending { control.requestPause() }
        let started = Date()
        SectorZeroWorkspace.throttle(
            100_000,
            startedAt: Date.timeIntervalSinceReferenceDate,
            control: control
        )
        return Date().timeIntervalSince(started)
    }

    @Test("Workspace reset republishes a clean consistent snapshot")
    func reset() {
        let workspace = workspaceWithBytes([0x90])
        workspace.step()
        #expect(workspace.machineSnapshot.cycleCount == 3)

        workspace.resetMachine()

        #expect(workspace.machineSnapshot == workspace.machine.snapshot())
        #expect(workspace.machineSnapshot.cycleCount == 0)
        #expect(workspace.machineSnapshot.cpu.ip == 0)
        #expect(workspace.lastRunStopReason == nil)
    }

    @Test("Run speed cap defaults to PC/XT speed")
    func defaultRunSpeedCap() {
        let workspace = SectorZeroWorkspace(userDefaults: isolatedDefaults())

        #expect(workspace.runSpeedCap == .pcXT)
        #expect(workspace.runSpeedCap.cyclesPerSecond == 4_770_000)
    }

    @Test("Run speed cap persists as a workspace preference")
    func runSpeedCapPersists() {
        let defaults = isolatedDefaults()
        let workspace = SectorZeroWorkspace(userDefaults: defaults)

        workspace.runSpeedCap = .khz500
        let reloaded = SectorZeroWorkspace(userDefaults: defaults)

        #expect(reloaded.runSpeedCap == .khz500)
        #expect(reloaded.runSpeedCap.cyclesPerSecond == 500_000)
    }

    @Test("Display refresh rate defaults to 60 Hz and persists")
    func displayRefreshRatePersists() {
        let defaults = isolatedDefaults()
        let workspace = SectorZeroWorkspace(userDefaults: defaults)

        #expect(workspace.displayRefreshRate == .fps60)
        workspace.displayRefreshRate = .fps120

        let reloaded = SectorZeroWorkspace(userDefaults: defaults)
        #expect(reloaded.displayRefreshRate == .fps120)
    }
}
