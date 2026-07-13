import SwiftUI

struct CPUInspectorView: View {
    let state: MachineSnapshot

    private var cpu: CPUStateSnapshot { state.cpu }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CPU 8086")
                .font(.sectorMono(12, weight: .semibold))
                .tracking(1.4)
                .foregroundStyle(Color.sectorHeading)

            registerSection("GENERAL", registers: cpu.generalRegisters)
            registerSection("INDEX", registers: cpu.indexRegisters)
            registerSection("POINTER", registers: cpu.pointerRegisters)
            registerSection("SEGMENT", registers: cpu.segmentRegisters)

            registerRow(name: "IP", value: cpu.ip)
            codeAddressSection

            Divider()
                .overlay(Color.sectorBorder)

            flagsSection
        }
        .padding(14)
        .frame(width: 236, alignment: .topLeading)
        .background(Color.sectorPanel)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.sectorBorder, lineWidth: 1)
        }
        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }

    private func registerSection(_ title: String, registers: [RegisterValue]) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle(title)
            ForEach(registers) { register in
                registerRow(name: register.name, value: register.value)
            }
        }
    }

    private func registerRow(name: String, value: UInt16) -> some View {
        valueRow(name: name, value: String(format: "%04X", value))
    }

    private var codeAddressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("CLOCK")
            valueRow(name: "CYC", value: String(state.cycleCount))
            valueRow(name: "CS:IP", value: String(format: "%04X:%04X", cpu.cs, cpu.ip))
            valueRow(name: "PHYS", value: String(format: "%05X", state.physicalCodeAddress))
            valueRow(name: "OPC", value: cpu.lastFetchedOpcodeText)
            valueRow(name: "KBD", value: keyboardText)
            stateRow
        }
    }

    /// Latched scan code and pending queue depth, e.g. "1E +2" or "-- +0".
    private var keyboardText: String {
        let ppi = state.peripheralInterface
        let latched = ppi.latchedScanCode.map { String(format: "%02X", $0) } ?? "--"
        return "\(latched) +\(ppi.pendingScanCodeCount)"
    }

    private var stateRow: some View {
        HStack(spacing: 8) {
            Text("STATE")
                .font(.sectorMono(11, weight: .semibold))
                .foregroundStyle(Color.sectorMutedText)
                .frame(width: 42, alignment: .leading)

            Spacer(minLength: 0)

            Text(stateText)
                .font(.sectorMono(12, weight: .semibold))
                .foregroundStyle(Color.sectorStatus(stateSeverity))
                .textSelection(.enabled)
        }
    }

    private var stateText: String {
        if cpu.fault != nil { return "FAULT" }
        if cpu.halted { return "HALT" }
        if cpu.waitingForCoprocessor { return "WAIT" }
        return "RUN"
    }

    private var stateSeverity: MachineCondition.Severity {
        if cpu.fault != nil { return .fault }
        if cpu.halted || cpu.waitingForCoprocessor { return .held }
        return .live
    }

    private func valueRow(name: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.sectorMono(11, weight: .semibold))
                .foregroundStyle(Color.sectorMutedText)
                .frame(width: 42, alignment: .leading)

            Spacer(minLength: 0)

            Text(value)
                .font(.sectorMono(12))
                .foregroundStyle(Color.sectorText)
                .textSelection(.enabled)
        }
    }

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("FLAGS")
            valueRow(name: "RAW", value: cpu.flags.hexValue)

            LazyVGrid(columns: flagColumns, alignment: .leading, spacing: 6) {
                ForEach(CPUFlag.allCases) { flag in
                    Text(flag.shortName)
                        .font(.sectorMono(10, weight: .semibold))
                        .foregroundStyle(cpu.flags[flag] ? Color.sectorAccent : Color.sectorMutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(flag.displayName)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.sectorMono(10, weight: .semibold))
            .tracking(1.2)
            .foregroundStyle(Color.sectorMutedText)
    }

    private var flagColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 28), spacing: 8), count: 3)
    }
}

#Preview {
    CPUInspectorView(state: Machine().snapshot())
        .padding()
        .background(Color.black)
}
