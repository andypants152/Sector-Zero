import SwiftUI

struct CPUInspectorView: View {
    let state: MachineSnapshot

    private var cpu: CPUStateSnapshot { state.cpu }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("CPU 8086")
                .font(.system(size: 12, weight: .semibold, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.cpuInspectorHeading)

            registerSection("GENERAL", registers: cpu.generalRegisters)
            registerSection("INDEX", registers: cpu.indexRegisters)
            registerSection("POINTER", registers: cpu.pointerRegisters)
            registerSection("SEGMENT", registers: cpu.segmentRegisters)

            registerRow(name: "IP", value: cpu.ip)
            codeAddressSection

            Divider()
                .overlay(Color.cpuInspectorBorder)

            flagsSection
        }
        .padding(14)
        .frame(width: 236, alignment: .topLeading)
        .background(Color.cpuInspectorBackground)
        .overlay {
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(Color.cpuInspectorBorder, lineWidth: 1)
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
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.cpuInspectorMutedText)
                .frame(width: 28, alignment: .leading)

            Spacer(minLength: 0)

            Text(String(format: "%04X", value))
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.cpuInspectorText)
                .textSelection(.enabled)
        }
    }

    private var codeAddressSection: some View {
        VStack(alignment: .leading, spacing: 6) {
            sectionTitle("CLOCK")
            valueRow(name: "CYC", value: String(state.cycleCount))
            valueRow(name: "CS:IP", value: String(format: "%04X:%04X", cpu.cs, cpu.ip))
            valueRow(name: "PHYS", value: String(format: "%05X", state.physicalCodeAddress))
            valueRow(name: "OPC", value: cpu.lastFetchedOpcodeText)
        }
    }

    private func valueRow(name: String, value: String) -> some View {
        HStack(spacing: 8) {
            Text(name)
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .foregroundStyle(Color.cpuInspectorMutedText)
                .frame(width: 42, alignment: .leading)

            Spacer(minLength: 0)

            Text(value)
                .font(.system(size: 12, weight: .medium, design: .monospaced))
                .foregroundStyle(Color.cpuInspectorText)
                .textSelection(.enabled)
        }
    }

    private var flagsSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            sectionTitle("FLAGS")
            HStack(spacing: 8) {
                Text("RAW")
                    .font(.system(size: 11, weight: .semibold, design: .monospaced))
                    .foregroundStyle(Color.cpuInspectorMutedText)
                Spacer(minLength: 0)
                Text(cpu.flags.hexValue)
                    .font(.system(size: 12, weight: .medium, design: .monospaced))
                    .foregroundStyle(Color.cpuInspectorText)
                    .textSelection(.enabled)
            }

            LazyVGrid(columns: flagColumns, alignment: .leading, spacing: 6) {
                ForEach(CPUFlag.allCases) { flag in
                    Text(flag.shortName)
                        .font(.system(size: 10, weight: .semibold, design: .monospaced))
                        .foregroundStyle(cpu.flags[flag] ? Color.cpuInspectorActiveFlag : Color.cpuInspectorMutedText)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .help(flag.displayName)
                }
            }
        }
    }

    private func sectionTitle(_ title: String) -> some View {
        Text(title)
            .font(.system(size: 10, weight: .semibold, design: .monospaced))
            .tracking(1.2)
            .foregroundStyle(Color.cpuInspectorMutedText)
    }

    private var flagColumns: [GridItem] {
        Array(repeating: GridItem(.flexible(minimum: 28), spacing: 8), count: 3)
    }
}

private extension Color {
    static let cpuInspectorBackground = Color(red: 0.028, green: 0.033, blue: 0.030)
    static let cpuInspectorBorder = Color(red: 0.12, green: 0.20, blue: 0.15)
    static let cpuInspectorText = Color(red: 0.76, green: 0.88, blue: 0.78)
    static let cpuInspectorHeading = Color(red: 0.64, green: 0.82, blue: 0.68)
    static let cpuInspectorMutedText = Color(red: 0.38, green: 0.50, blue: 0.41)
    static let cpuInspectorActiveFlag = Color(red: 0.92, green: 0.74, blue: 0.34)
}

#Preview {
    CPUInspectorView(state: Machine().snapshot())
        .padding()
        .background(Color.black)
}
