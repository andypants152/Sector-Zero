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
}
