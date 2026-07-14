import SwiftUI

struct CPUInspectorView: View {
    let state: MachineSnapshot
    var showsHeader = true

    private var cpu: CPUStateSnapshot { state.cpu }

    var body: some View {
        VStack(spacing: 0) {
            if showsHeader {
                inspectorHeader
                Divider().overlay(Color.sectorBorder)
            }

            ScrollView {
                VStack(alignment: .leading, spacing: 16) {
                    registerGrid
                    executionSection
                    deviceSection
                    flagsSection
                }
                .padding(13)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .modifier(CPUInspectorContainerStyle(isEnabled: showsHeader))
        .accessibilityLabel("8086 inspector")
    }

    private var inspectorHeader: some View {
        HStack(spacing: 9) {
            Image(systemName: "cpu")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Color.sectorHeading)
            VStack(alignment: .leading, spacing: 1) {
                Text("CPU INSPECTOR")
                    .font(.sectorMono(10, weight: .bold))
                    .tracking(1.1)
                    .foregroundStyle(Color.sectorHeading)
                Text("INTEL 8086")
                    .font(.sectorMono(8, weight: .medium))
                    .tracking(0.8)
                    .foregroundStyle(Color.sectorMutedText)
            }
            Spacer(minLength: 0)
            Text(stateText)
                .font(.sectorMono(9, weight: .bold))
                .tracking(0.8)
                .foregroundStyle(Color.sectorStatus(stateSeverity))
                .padding(.horizontal, 7)
                .frame(height: 22)
                .background(Color.sectorStatus(stateSeverity).opacity(0.08))
                .clipShape(Capsule())
                .help(stateTooltip)
        }
        .padding(.horizontal, 13)
        .frame(height: 46)
    }

    private var registerGrid: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectorSectionLabel(title: "REGISTERS")
            LazyVGrid(columns: registerColumns, spacing: 6) {
                ForEach(allRegisters) { register in
                    VStack(alignment: .leading, spacing: 4) {
                        Text(register.name)
                            .font(.sectorMono(9, weight: .bold))
                            .foregroundStyle(Color.sectorMutedText)
                        Text(String(format: "%04X", register.value))
                            .font(.sectorMono(13, weight: .semibold))
                            .foregroundStyle(Color.sectorText)
                            .textSelection(.enabled)
                    }
                    .padding(.horizontal, 9)
                    .padding(.vertical, 7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.sectorElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 6, style: .continuous)
                            .stroke(Color.sectorBorder.opacity(0.72), lineWidth: 1)
                    }
                    .help(registerTooltip(register.name))
                    .accessibilityLabel("\(register.name), \(registerTooltip(register.name)): \(String(format: "%04X", register.value)) hexadecimal")
                }
            }
        }
    }

    private var executionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectorSectionLabel(title: "EXECUTION")
            VStack(spacing: 7) {
                valueRow(name: "CS:IP", value: String(format: "%04X:%04X", cpu.cs, cpu.ip), emphasis: true, help: "Code Segment : Instruction Pointer. Together they locate the next instruction the 8086 will fetch.")
                valueRow(name: "PHYSICAL", value: String(format: "%05X", state.physicalCodeAddress), help: "The 20-bit memory address produced from CS:IP: (CS × 16) + IP.")
                valueRow(name: "OPCODE", value: cpu.lastFetchedOpcodeText, help: "The first byte of the most recently fetched instruction, shown in hexadecimal. -- means nothing has been fetched since reset.")
                valueRow(name: "CYCLES", value: String(state.cycleCount), help: "Total emulated 8086 clock cycles elapsed since reset; this is machine time, not wall-clock time.")
            }
            .padding(10)
            .background(Color.sectorElevated)
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }

    private var deviceSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectorSectionLabel(title: "DEVICES")
            HStack(spacing: 6) {
                deviceTile("KBD", value: keyboardText, systemImage: "keyboard", help: "Keyboard. The XT keyboard sends scan codes through the 8255 peripheral interface; Q is the number still queued.")
                deviceTile("FDC", value: floppyText, systemImage: "externaldrive", help: "Floppy Disk Controller. It reads floppy sectors and coordinates DMA transfers into RAM.")
            }
        }
    }

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                SectorSectionLabel(title: "FLAGS")
                Spacer(minLength: 0)
                Text(cpu.flags.hexValue)
                    .font(.sectorMono(10, weight: .semibold))
                    .foregroundStyle(Color.sectorText)
                    .textSelection(.enabled)
            }

            LazyVGrid(columns: flagColumns, spacing: 6) {
                ForEach(CPUFlag.allCases) { flag in
                    Text(flag.shortName)
                        .font(.sectorMono(9, weight: .bold))
                        .foregroundStyle(cpu.flags[flag] ? Color.sectorAccent : Color.sectorMutedText)
                        .frame(maxWidth: .infinity)
                        .frame(height: 24)
                        .background(cpu.flags[flag] ? Color.sectorAccent.opacity(0.09) : Color.sectorElevated)
                        .clipShape(RoundedRectangle(cornerRadius: 5, style: .continuous))
                        .overlay {
                            RoundedRectangle(cornerRadius: 5, style: .continuous)
                                .stroke(cpu.flags[flag] ? Color.sectorAccent.opacity(0.3) : Color.sectorBorder.opacity(0.6), lineWidth: 1)
                        }
                        .help(flagTooltip(flag))
                        .accessibilityLabel("\(flag.displayName): \(cpu.flags[flag] ? "set" : "clear")")
                }
            }
        }
    }

    private func valueRow(name: String, value: String, emphasis: Bool = false, help: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.sectorMono(9, weight: .bold))
                .foregroundStyle(Color.sectorMutedText)
            Spacer(minLength: 0)
            Text(value)
                .font(.sectorMono(emphasis ? 12 : 11, weight: emphasis ? .semibold : .medium))
                .foregroundStyle(emphasis ? Color.sectorHeading : Color.sectorText)
                .textSelection(.enabled)
        }
        .help(help)
    }

    private func deviceTile(_ title: String, value: String, systemImage: String, help: String) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 5) {
                Image(systemName: systemImage)
                Text(title)
            }
            .font(.sectorMono(8, weight: .bold))
            .foregroundStyle(Color.sectorMutedText)
            Text(value)
                .font(.sectorMono(10, weight: .semibold))
                .foregroundStyle(Color.sectorText)
                .lineLimit(1)
        }
        .padding(9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.sectorElevated)
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        .help(help)
    }

    private var allRegisters: [RegisterValue] {
        cpu.generalRegisters
            + cpu.indexRegisters
            + cpu.pointerRegisters
            + cpu.segmentRegisters
            + [RegisterValue(name: "IP", value: cpu.ip)]
    }

    private var keyboardText: String {
        let ppi = state.peripheralInterface
        let latched = ppi.latchedScanCode.map { String(format: "%02X", $0) } ?? "--"
        return "\(latched) · Q\(ppi.pendingScanCodeCount)"
    }

    private var floppyText: String {
        let floppy = state.floppyController
        guard floppy.mediaGeometry != nil else { return "EMPTY" }
        switch floppy.phase {
        case .idle: return "READY"
        case .command: return "COMMAND"
        case .execution: return "DMA"
        case .result: return "RESULT"
        }
    }

    private var stateText: String {
        if cpu.fault != nil { return "FAULT" }
        if cpu.halted { return "HALT" }
        if cpu.waitingForCoprocessor { return "WAIT" }
        return "LIVE"
    }

    private var stateSeverity: MachineCondition.Severity {
        if cpu.fault != nil { return .fault }
        if cpu.halted || cpu.waitingForCoprocessor { return .held }
        return .live
    }

    private var stateTooltip: String {
        if cpu.fault != nil { return "FAULT: execution stopped because the emulator detected an error." }
        if cpu.halted { return "HALT: the CPU executed HLT and waits for a qualifying interrupt or reset." }
        if cpu.waitingForCoprocessor { return "WAIT: the CPU is waiting for the absent 8087 coprocessor endpoint." }
        return "LIVE: the CPU is able to execute instructions."
    }

    private func registerTooltip(_ name: String) -> String {
        return switch name {
        case "AX": "Accumulator register. Used by arithmetic and many instructions as an implicit operand."
        case "BX": "Base register. Often holds a base address when forming memory addresses."
        case "CX": "Count register. Used by loops, shifts, and REP string instructions."
        case "DX": "Data register. Extends arithmetic results and selects many I/O ports."
        case "SI": "Source Index. Points to source data for string and indexed-memory instructions."
        case "DI": "Destination Index. Points to destination data for string and indexed-memory instructions."
        case "SP": "Stack Pointer. Offset of the top of the current stack within SS."
        case "BP": "Base Pointer. Commonly addresses stack-frame data; memory operands using BP default to SS."
        case "CS": "Code Segment. Base segment for instruction fetches; combined with IP to locate code."
        case "DS": "Data Segment. Default base segment for ordinary data-memory operands."
        case "ES": "Extra Segment. An additional data segment, commonly the destination for string instructions."
        case "SS": "Stack Segment. Base segment used by PUSH, POP, CALL, RET, and stack-addressed memory."
        case "IP": "Instruction Pointer. Offset of the next instruction within CS."
        default: "16-bit 8086 register."
        }
    }

    private func flagTooltip(_ flag: CPUFlag) -> String {
        let state = cpu.flags[flag] ? "Set" : "Clear"
        let meaning: String
        switch flag {
        case .carry: meaning = "Carry Flag: unsigned carry or borrow from the most significant bit."
        case .parity: meaning = "Parity Flag: set when the low result byte contains an even number of set bits."
        case .auxiliaryCarry: meaning = "Auxiliary Carry Flag: carry or borrow between bits 3 and 4, used by decimal adjustments."
        case .zero: meaning = "Zero Flag: set when an arithmetic or logical result is zero."
        case .sign: meaning = "Sign Flag: copies the most significant bit of an arithmetic or logical result."
        case .trap: meaning = "Trap Flag: requests a single-step interrupt after each instruction."
        case .interruptEnable: meaning = "Interrupt Enable Flag: permits maskable hardware interrupts when set."
        case .direction: meaning = "Direction Flag: controls whether string instructions increment or decrement index registers."
        case .overflow: meaning = "Overflow Flag: set when a signed arithmetic result cannot fit in its destination."
        }
        return "\(state). \(meaning)"
    }

    private var registerColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    }

    private var flagColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
    }
}

private struct CPUInspectorContainerStyle: ViewModifier {
    let isEnabled: Bool

    func body(content: Content) -> some View {
        if isEnabled {
            content
                .frame(width: 252)
                .sectorCard()
        } else {
            content
        }
    }
}

#Preview {
    CPUInspectorView(state: Machine().snapshot())
        .frame(height: 720)
        .padding()
        .background(Color.sectorWorkspace)
}
