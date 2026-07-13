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

    private func waitUntil(
        timeoutNanoseconds: UInt64 = 2_000_000_000,
        _ condition: @escaping @MainActor () -> Bool
    ) async -> Bool {
        let deadline = ContinuousClock.now + .nanoseconds(Int64(timeoutNanoseconds))
        while ContinuousClock.now < deadline {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 1_000_000)
        }
        return condition()
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

    @Test("PAUSE interrupts a pending speed-cap wait promptly")
    func pauseInterruptsThrottle() async {
        // AAM (83 clocks) plus the short jump (15 clocks) makes each 2,048
        // instruction slice take about 0.4 seconds at 250 KHz.
        let workspace = workspaceWithBytes([0xD4, 0x0A, 0xEB, 0xFC])
        workspace.runSpeedCap = .khz250

        workspace.run()
        try? await Task.sleep(nanoseconds: 50_000_000)
        let pauseStarted = Date.timeIntervalSinceReferenceDate
        workspace.pause()

        #expect(await waitUntil { !workspace.isRunning })
        #expect(Date.timeIntervalSinceReferenceDate - pauseStarted < 0.2)
        #expect(workspace.lastRunStopReason == .paused)
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
}
