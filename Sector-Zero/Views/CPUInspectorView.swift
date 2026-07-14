import SwiftUI

struct CPUInspectorView: View {
    let state: MachineSnapshot

    private var cpu: CPUStateSnapshot { state.cpu }

    var body: some View {
        VStack(spacing: 0) {
            inspectorHeader
            Divider().overlay(Color.sectorBorder)

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
        .frame(width: 252)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sectorCard()
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
                }
            }
        }
    }

    private var executionSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            SectorSectionLabel(title: "EXECUTION")
            VStack(spacing: 7) {
                valueRow(name: "CS:IP", value: String(format: "%04X:%04X", cpu.cs, cpu.ip), emphasis: true)
                valueRow(name: "PHYSICAL", value: String(format: "%05X", state.physicalCodeAddress))
                valueRow(name: "OPCODE", value: cpu.lastFetchedOpcodeText)
                valueRow(name: "CYCLES", value: String(state.cycleCount))
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
                deviceTile("KBD", value: keyboardText, systemImage: "keyboard")
                deviceTile("FDC", value: floppyText, systemImage: "externaldrive")
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
                        .help(flag.displayName)
                        .accessibilityLabel("\(flag.displayName): \(cpu.flags[flag] ? "set" : "clear")")
                }
            }
        }
    }

    private func valueRow(name: String, value: String, emphasis: Bool = false) -> some View {
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
    }

    private func deviceTile(_ title: String, value: String, systemImage: String) -> some View {
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

    private var registerColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 3)
    }

    private var flagColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(), spacing: 6), count: 4)
    }
}

#Preview {
    CPUInspectorView(state: Machine().snapshot())
        .frame(height: 720)
        .padding()
        .background(Color.sectorWorkspace)
}
