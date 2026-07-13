import Foundation
import Testing
@testable import Sector_Zero

@MainActor
struct WorkspaceStatusTests {
    /// Builds a workspace whose machine carries real firmware: the code is
    /// padded with HLT to 16 bytes so the top-aligned image starts exactly at
    /// the reset vector. Real firmware (not `loadBytes`) keeps the machine
    /// out of the NO ROM condition, which these tests are not about.
    private func workspaceWithBytes(_ code: [UInt8]) -> SectorZeroWorkspace {
        let machine = Machine()
        let image = Data(code + Array(repeating: UInt8(0xF4), count: 16 - code.count))
        try! machine.loadSystemROM(image)
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

    @Test("A fresh workspace reports READY with no condition detail")
    func freshWorkspaceIsReady() {
        let workspace = workspaceWithBytes([0x90])

        #expect(workspace.machineCondition == MachineCondition(label: "READY", severity: .ready))
        #expect(workspace.machineConditionDetail == nil)
    }

    @Test("Running reports RUNNING, then HALT with detail once HLT lands")
    func runningThenHalted() async {
        let workspace = workspaceWithBytes([0x90, 0xF4])

        workspace.run()
        #expect(workspace.machineCondition == MachineCondition(label: "RUNNING", severity: .live))
        #expect(workspace.machineConditionDetail == nil)
        #expect(await waitUntil { !workspace.isRunning })

        #expect(workspace.machineCondition == MachineCondition(label: "HALT", severity: .held))
        #expect(workspace.machineConditionDetail == "CPU halted")
    }

    @Test("Pausing an unbounded program reports PAUSED with detail")
    func paused() async {
        let workspace = workspaceWithBytes([0xEB, 0xFE]) // JMP short to self

        workspace.run()
        #expect(await waitUntil { workspace.machineSnapshot.cycleCount > 0 })
        workspace.pause()
        #expect(await waitUntil { !workspace.isRunning })

        #expect(workspace.machineCondition == MachineCondition(label: "PAUSED", severity: .held))
        #expect(workspace.machineConditionDetail == "Paused at instruction boundary")
    }

    @Test("A CPU fault outranks the halted flag and names the opcode")
    func faultFromStep() {
        let workspace = workspaceWithBytes([0x60]) // unsupported on the 8086

        workspace.step()

        #expect(workspace.machineSnapshot.cpu.fault == .unsupportedOpcode(0x60))
        #expect(workspace.machineSnapshot.cpu.halted)
        #expect(workspace.machineCondition == MachineCondition(label: "FAULT", severity: .fault))
        #expect(workspace.machineConditionDetail == "Fault: unsupported opcode 60")
    }

    @Test("Reset returns a faulted machine to READY")
    func resetClearsCondition() {
        let workspace = workspaceWithBytes([0x60])
        workspace.step()
        #expect(workspace.machineCondition.severity == .fault)

        workspace.resetMachine()

        #expect(workspace.machineCondition == MachineCondition(label: "READY", severity: .ready))
        #expect(workspace.machineConditionDetail == nil)
    }
}
