import Foundation
import Testing
@testable import Sector_Zero

struct MachineExplanationTests {
    private func firmwareMachine() -> Machine {
        let machine = Machine()
        try! machine.loadSystemROM(Data(repeating: 0x90, count: 16))
        return machine
    }

    private func explanation(
        _ machine: Machine,
        builtIn: Bool = true,
        condition: MachineCondition = MachineCondition(label: "READY", severity: .ready),
        detail: String? = nil
    ) -> MachineExplanation {
        MachineExplanationMapper.make(
            snapshot: machine.snapshot(),
            condition: condition,
            conditionDetail: detail,
            usesBuiltInFirmware: builtIn
        )
    }

    @Test("Built-in BIOS diagnostic codes map to named observed boot phases")
    func builtInMilestones() {
        let machine = firmwareMachine()
        let expected: [(UInt8, String)] = [
            (0x10, "cold-post"), (0x11, "warm-post"), (0x20, "ivt"),
            (0x30, "video-memory"), (0x40, "devices"), (0x50, "platform-ready"),
            (0xAA, "post-reported"), (0xB0, "boot-read"), (0xB1, "boot-signature"),
            (0xB2, "boot-handoff-pending"), (0xE1, "boot-read-failed"),
            (0xE2, "boot-signature-failed"), (0xF1, "post-failed")
        ]

        for (code, phaseID) in expected {
            machine.diagnosticPort.reset()
            machine.diagnosticPort.writeByte(code, to: DiagnosticPort.port)
            let result = explanation(machine)
            #expect(result.phaseID == phaseID)
            #expect(result.confidence == .observed)
        }
    }

    @Test("Custom firmware never receives built-in BIOS phase names")
    func customFirmwareIsGeneric() {
        let machine = firmwareMachine()
        machine.diagnosticPort.writeByte(0xB0, to: DiagnosticPort.port)

        let result = explanation(machine, builtIn: false)

        #expect(result.phaseID == "reset-vector")
        #expect(result.title != "Reading sector zero")
    }

    @Test("Reset, handoff, and terminal states have truthful explanations")
    func stateTransitions() {
        let machine = firmwareMachine()
        #expect(explanation(machine).phaseID == "reset-vector")

        // Far jump from the reset vector to the conventional boot address.
        try! machine.bus.loadBytes([0xEA, 0x00, 0x7C, 0x00, 0x00], at: 0xFFFF0)
        machine.step()
        #expect(explanation(machine).phaseID == "boot-handoff")

        try! machine.bus.loadBytes([0xE9, 0x00, 0x04], at: 0x07C00)
        machine.step()
        #expect(explanation(machine).phaseID == "guest-execution")

        try! machine.bus.loadBytes([0xF4], at: 0x08003)
        machine.step()
        let stopped = explanation(machine, condition: MachineCondition(label: "HALT", severity: .held), detail: "CPU halted")
        #expect(stopped.phaseID == "stopped")

        let fault = explanation(machine, condition: MachineCondition(label: "FAULT", severity: .fault), detail: "Fault: unsupported opcode 60")
        #expect(fault.phaseID == "fault")
    }

    @Test("No ROM explains why the CPU cannot begin")
    func noROM() {
        let machine = Machine()
        let result = explanation(machine, builtIn: false, condition: MachineCondition(label: "NO ROM", severity: .held))
        #expect(result.phaseID == "no-rom")
        #expect(result.confidence == .observed)
    }
}
