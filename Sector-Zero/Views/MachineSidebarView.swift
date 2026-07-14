import SwiftUI

struct MachineSidebarView: View {
    enum Mode: String, CaseIterable, Identifiable {
        case inspect = "INSPECT"
        case explain = "EXPLAIN"

        var id: String { rawValue }
    }

    @Bindable var workspace: SectorZeroWorkspace
    @State private var mode: Mode = .inspect

    var body: some View {
        VStack(spacing: 0) {
            Picker("Sidebar mode", selection: $mode) {
                ForEach(Mode.allCases) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .padding(10)
            .accessibilityIdentifier("machineSidebarModePicker")
            .accessibilityLabel("Machine sidebar mode")

            Divider().overlay(Color.sectorBorder)

            if mode == .inspect {
                CPUInspectorView(state: workspace.machineSnapshot, showsHeader: false)
            } else {
                MachineExplanationView(explanation: explanation)
            }
        }
        .frame(width: 252)
        .frame(maxHeight: .infinity, alignment: .topLeading)
        .sectorCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel(mode == .inspect ? "8086 inspector" : "Machine explanation")
    }

    private var explanation: MachineExplanation {
        MachineExplanationMapper.make(
            snapshot: workspace.machineSnapshot,
            condition: workspace.machineCondition,
            conditionDetail: workspace.machineConditionDetail,
            usesBuiltInFirmware: workspace.currentProject?.usesBuiltInFirmware == true
        )
    }
}

private struct MachineExplanationView: View {
    let explanation: MachineExplanation

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 7) {
                    HStack {
                        Text(explanation.confidence.rawValue)
                            .font(.sectorMono(9, weight: .bold))
                            .tracking(0.8)
                            .foregroundStyle(explanation.confidence == .observed ? Color.sectorRun : Color.sectorAccent)
                            .padding(.horizontal, 7)
                            .frame(height: 21)
                            .background((explanation.confidence == .observed ? Color.sectorRun : Color.sectorAccent).opacity(0.1))
                            .clipShape(Capsule())
                            .help(explanation.confidence == .observed ? "Directly supported by current machine state." : "An interpretation based on current machine state.")
                        Spacer(minLength: 0)
                    }
                    Text(explanation.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundStyle(Color.sectorHeading)
                    Text(explanation.summary)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sectorText)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .accessibilityElement(children: .combine)
                .accessibilityIdentifier("machineExplanationPhase")
                .accessibilityLabel("\(explanation.confidence.rawValue): \(explanation.title). \(explanation.summary)")

                section("WHAT THIS MEANS") {
                    Text(explanation.meaning)
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sectorMutedText)
                        .fixedSize(horizontal: false, vertical: true)
                    if let nextStep = explanation.nextStep {
                        Label(nextStep, systemImage: "arrow.right.circle")
                            .font(.system(size: 10, weight: .medium))
                            .foregroundStyle(Color.sectorAccent)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }

                section("LIVE EVIDENCE") {
                    VStack(spacing: 6) {
                        ForEach(explanation.evidence) { item in
                            HStack(spacing: 8) {
                                Text(item.label)
                                    .font(.sectorMono(8, weight: .bold))
                                    .foregroundStyle(Color.sectorMutedText)
                                    .frame(width: 53, alignment: .leading)
                                    .help(item.detail)
                                Text(item.value)
                                    .font(.sectorMono(10, weight: .semibold))
                                    .foregroundStyle(Color.sectorText)
                                Spacer(minLength: 0)
                            }
                        }
                    }
                    .accessibilityIdentifier("machineExplanationEvidence")
                    .accessibilityLabel("Live machine evidence")
                }

                section("GLOSSARY") {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(explanation.glossary) { item in
                            VStack(alignment: .leading, spacing: 2) {
                                Text(item.term.uppercased())
                                    .font(.sectorMono(9, weight: .bold))
                                    .foregroundStyle(Color.sectorHeading)
                                Text(item.definition)
                                    .font(.system(size: 10))
                                    .foregroundStyle(Color.sectorMutedText)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                        }
                    }
                }
            }
            .padding(13)
        }
    }

    private func section<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            SectorSectionLabel(title: title)
            content()
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.sectorElevated)
                .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
    }
}
