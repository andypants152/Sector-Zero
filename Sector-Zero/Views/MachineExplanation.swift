import Foundation

/// A display-ready explanation derived only from published workspace state.
/// It deliberately makes no claims about guest intent beyond the evidence it
/// has; BIOS-specific milestones require explicit bundled-firmware provenance.
struct MachineExplanation: Equatable {
    enum Confidence: String, Equatable {
        case observed = "OBSERVED"
        case likely = "LIKELY"
    }

    struct Evidence: Equatable, Identifiable {
        let label: String
        let value: String
        let detail: String

        var id: String { label }
    }

    struct GlossaryTerm: Equatable, Identifiable {
        let term: String
        let definition: String

        var id: String { term }
    }

    let phaseID: String
    let title: String
    let confidence: Confidence
    let summary: String
    let meaning: String
    let nextStep: String?
    let evidence: [Evidence]
    let glossary: [GlossaryTerm]
}

enum MachineExplanationMapper {
    static func make(
        snapshot: MachineSnapshot,
        condition: MachineCondition,
        conditionDetail: String?,
        usesBuiltInFirmware: Bool
    ) -> MachineExplanation {
        let evidence = standardEvidence(snapshot: snapshot, condition: condition)

        if snapshot.loadedSystemROMByteCount == 0 {
            return explanation(
                "no-rom", "No firmware loaded", .observed,
                "The CPU has no system ROM to fetch its reset instruction from.",
                "On an original PC, power-on begins at the reset vector in system ROM. Install firmware before running.",
                "Install the built-in BIOS or choose a ROM image.", evidence,
                [glossary("System ROM", "Read-only firmware that starts the machine.")]
            )
        }

        if let detail = conditionDetail, condition.severity == .fault {
            return explanation(
                "fault", "Execution stopped on a fault", .observed,
                detail,
                "The emulator stopped at an instruction boundary so its CPU and device state can be inspected safely.",
                "Inspect the opcode and code address, then reset or adjust the firmware.", evidence,
                [glossary("Instruction boundary", "The point between complete CPU instructions where execution can safely stop.")]
            )
        }

        if snapshot.cpu.halted || snapshot.cpu.waitingForCoprocessor || condition.label == "PAUSED" || condition.label == "BREAK" {
            return explanation(
                "stopped", "Execution is paused", .observed,
                conditionDetail ?? "The machine is not currently executing instructions.",
                "The displayed registers and devices are a consistent snapshot at the last instruction boundary.",
                "Use Step to advance one instruction or Run to continue.", evidence,
                [glossary("HALT", "An 8086 instruction that stops normal execution until a qualifying interrupt arrives.")]
            )
        }

        if isBootSector(snapshot) {
            return explanation(
                "boot-handoff", "Boot sector now controls the CPU", .observed,
                "Execution has reached the conventional boot address 0000:7C00.",
                "Firmware has handed control to code loaded from the first floppy sector. The explainer now follows live execution rather than BIOS startup phases.",
                nil, evidence,
                [glossary("Boot sector", "The first 512-byte sector of a bootable disk, loaded by firmware before it runs.")]
            )
        }

        if snapshot.physicalCodeAddress < 0xF0000 {
            return explanation(
                "guest-execution", "Executing code outside system ROM", .observed,
                "The next instruction is at \(hex(snapshot.physicalCodeAddress, width: 5))h, outside the firmware address range.",
                "The CPU is now following program code in RAM or adapter space. Use the opcode, flags, and device evidence below to connect each execution stop to machine state.",
                "Step to inspect one instruction boundary at a time.", evidence,
                [
                    glossary("Opcode", "The first byte of an instruction; it tells the CPU what operation to decode."),
                    glossary("Flags", "Bits that record arithmetic results and control selected CPU behavior.")
                ]
            )
        }

        if usesBuiltInFirmware, let code = snapshot.diagnosticPort.lastCode,
           let milestone = builtInMilestone(for: code) {
            return explanation(
                milestone.id, milestone.title, .observed, milestone.summary,
                milestone.meaning, milestone.nextStep, evidence,
                milestone.glossary
            )
        }

        if snapshot.physicalCodeAddress == 0xFFFF0 {
            return explanation(
                "reset-vector", "CPU is at the reset vector", .observed,
                "The 8086 will fetch its first instruction from physical address FFFF0h.",
                "Reset starts at CS:IP FFFF:0000. The segment:offset pair is translated into a 20-bit physical address before the ROM is read.",
                "Step once to begin firmware execution.", evidence,
                [
                    glossary("Reset vector", "The fixed address where the CPU begins after reset."),
                    glossary("CS:IP", "Code Segment and Instruction Pointer; together they locate the next instruction.")
                ]
            )
        }

        return explanation(
            usesBuiltInFirmware ? "firmware-between-milestones" : "firmware-generic",
            "Firmware is executing", .likely,
            "The CPU is executing code from system ROM at \(hex(snapshot.physicalCodeAddress, width: 5))h.",
            "Firmware prepares hardware and may use interrupts, ports, memory, and devices before it transfers control to a boot program.",
            usesBuiltInFirmware ? "The next observed BIOS milestone will replace this estimate." : nil,
            evidence,
            [
                glossary("Firmware", "Low-level code in ROM that initializes the machine before an operating system or boot program runs."),
                glossary("Physical address", "The 20-bit memory address produced from an 8086 segment and offset.")
            ]
        )
    }

    private static func standardEvidence(snapshot: MachineSnapshot, condition: MachineCondition) -> [MachineExplanation.Evidence] {
        let floppy = snapshot.floppyController
        let floppyValue: String
        switch floppy.phase {
        case .idle: floppyValue = floppy.mediaGeometry == nil ? "No media" : "Ready"
        case .command: floppyValue = "Command"
        case .execution: floppyValue = "DMA transfer"
        case .result: floppyValue = "Result"
        }
        return [
            .init(label: "NEXT", value: String(format: "%04X:%04X", snapshot.cpu.cs, snapshot.cpu.ip), detail: "Next instruction (CS:IP)"),
            .init(label: "ADDRESS", value: hex(snapshot.physicalCodeAddress, width: 5) + "h", detail: "Translated physical code address"),
            .init(label: "OPCODE", value: snapshot.cpu.lastFetchedOpcodeText, detail: "Most recently fetched instruction opcode"),
            .init(label: "FLAGS", value: snapshot.cpu.flags.hexValue, detail: "8086 status and control flags"),
            .init(label: "CYCLES", value: "\(snapshot.cycleCount)", detail: "Emulated 8086 clocks elapsed"),
            .init(label: "STATE", value: condition.label, detail: "Current execution state"),
            .init(label: "ROM", value: "\(snapshot.loadedSystemROMByteCount) B", detail: "Loaded system ROM"),
            .init(label: "FLOPPY", value: floppyValue, detail: "Floppy controller state"),
            .init(label: "PIC", value: snapshot.interruptController.initialized ? "Ready" : "Reset", detail: "Programmable interrupt controller"),
            .init(label: "POST", value: snapshot.diagnosticPort.lastCode.map { hex($0, width: 2) + "h" } ?? "--", detail: "Latest firmware diagnostic-port code")
        ]
    }

    private static func isBootSector(_ snapshot: MachineSnapshot) -> Bool {
        snapshot.cpu.cs == 0 && (0x7C00...0x7DFF).contains(snapshot.cpu.ip)
    }

    private static func explanation(
        _ id: String, _ title: String, _ confidence: MachineExplanation.Confidence,
        _ summary: String, _ meaning: String, _ nextStep: String?,
        _ evidence: [MachineExplanation.Evidence], _ glossary: [MachineExplanation.GlossaryTerm]
    ) -> MachineExplanation {
        MachineExplanation(phaseID: id, title: title, confidence: confidence, summary: summary, meaning: meaning, nextStep: nextStep, evidence: evidence, glossary: glossary)
    }

    private static func glossary(_ term: String, _ definition: String) -> MachineExplanation.GlossaryTerm {
        .init(term: term, definition: definition)
    }

    private static func hex(_ value: some BinaryInteger, width: Int) -> String {
        String(format: "%0*X", width, Int(value))
    }

    private static func builtInMilestone(for code: UInt8) -> (id: String, title: String, summary: String, meaning: String, nextStep: String?, glossary: [MachineExplanation.GlossaryTerm])? {
        switch code {
        case 0x10: return milestone("cold-post", "Cold boot begins", "The built-in BIOS has started a cold power-on sequence.", "It will establish safe CPU state and build the machine services that later software expects.", "Watch for the interrupt-vector setup milestone.", "POST", "Power-on self-test: firmware checks and initializes the platform.")
        case 0x11: return milestone("warm-post", "Warm boot begins", "The built-in BIOS detected a warm-boot request.", "A warm boot follows the same firmware entry point but can skip work intended only for a cold power-on.", nil, "Warm boot", "A reset request made by software rather than a fresh power-on.")
        case 0x20: return milestone("ivt", "Installing interrupt vectors", "The BIOS is publishing firmware handlers in the interrupt vector table.", "An interrupt number indexes a four-byte CS:IP entry in low memory, letting hardware and software transfer control to firmware routines.", "Next the BIOS prepares video and RAM.", "IVT", "Interrupt Vector Table: 256 low-memory pointers to interrupt handlers.")
        case 0x30: return milestone("video-memory", "Testing video and memory", "The BIOS has initialized CGA text memory and is checking conventional RAM.", "CGA text cells live at B8000h; firmware writes them directly before higher-level display services exist.", nil, "CGA", "Color Graphics Adapter; this machine models its 80×25 text mode.")
        case 0x40: return milestone("devices", "Probing floppy hardware", "The BIOS has reached the floppy-controller check before enabling normal interrupt routing.", "A floppy read uses the controller, DMA channel 2, and IRQ6 together rather than copying each byte with the CPU.", nil, "DMA", "Direct Memory Access: a controller transfers data between a device and RAM.")
        case 0x50: return milestone("platform-ready", "Platform services are ready", "The BIOS has configured the PIC, PIT, keyboard handshake, and BIOS data area.", "The PIC routes device interrupt requests, while the PIT supplies the periodic timer tick used by PC firmware.", "The BIOS will report POST status and attempt to boot media.", "PIC", "Programmable Interrupt Controller: prioritizes hardware interrupt requests.")
        case 0xAA: return milestone("post-reported", "POST reported to the display", "The BIOS has displayed its POST result through its CGA services.", "This confirms firmware can use the video service layer it just installed, not merely write raw screen memory.", "Next it will attempt to load sector zero.", "INT 10h", "The BIOS video-service interrupt used by software to control text display.")
        case 0xB0: return milestone("boot-read", "Reading sector zero", "The BIOS requested the first sector of floppy drive A into 0000:7C00.", "The request travels through INT 13h to the floppy controller; DMA moves the sector into RAM and IRQ6 signals completion.", "Watch for boot-signature validation.", "INT 13h", "The BIOS disk-service interrupt.")
        case 0xB1: return milestone("boot-signature", "Validating the boot sector", "The BIOS read completed and it is checking the required 55AAh signature.", "The signature distinguishes a bootable first sector from arbitrary disk data before firmware gives it control.", "A valid sector will be handed control at 0000:7C00.", "55AAh signature", "The two-byte marker at the end of a bootable sector.")
        case 0xB2: return milestone("boot-handoff-pending", "Preparing boot handoff", "The boot sector passed validation; the BIOS is clearing registers and preparing to jump to it.", "This standardized starting state lets boot code begin without inheriting unpredictable firmware values.", "The next phase is observed when CS:IP reaches 0000:7C00.", "Far jump", "A control transfer that loads both a code segment and instruction pointer.")
        case 0xE1: return milestone("boot-read-failed", "Boot read failed", "The BIOS could not read sector zero from the floppy.", "Without a boot sector in RAM, firmware cannot transfer control to a disk program.", nil, "Sector zero", "The first sector of a disk, conventionally used as its boot sector.")
        case 0xE2: return milestone("boot-signature-failed", "Boot signature missing", "The floppy read completed, but the sector did not end with the 55AAh boot marker.", "The BIOS rejects the sector instead of executing arbitrary disk bytes.", nil, "Boot signature", "The marker firmware requires before executing a boot sector.")
        case 0xF1, 0xF2, 0xF3, 0xF6: return milestone("post-failed", "POST detected a hardware failure", "The built-in BIOS reported a failed platform check (code \(hex(code, width: 2))h).", "The machine stops rather than attempting to boot with a failed essential subsystem.", nil, "POST", "Power-on self-test: firmware checks and initializes the platform.")
        default: return nil
        }
    }

    private static func milestone(_ id: String, _ title: String, _ summary: String, _ meaning: String, _ next: String?, _ term: String, _ definition: String) -> (id: String, title: String, summary: String, meaning: String, nextStep: String?, glossary: [MachineExplanation.GlossaryTerm]) {
        (id, title, summary, meaning, next, [glossary(term, definition)])
    }
}
