//
//  SectorZeroWorkspaceView.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import SwiftUI
#if os(macOS)
import AppKit
#endif

struct SectorZeroWorkspaceView: View {
    @Bindable var workspace: SectorZeroWorkspace
    @Environment(\.horizontalSizeClass) private var horizontalSizeClass

    var body: some View {
        Group {
            if isCompact {
                compactLayout
            } else {
                regularLayout
            }
        }
        .safeAreaPadding(12)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sectorWorkspace)
        .alert("Machine Error", isPresented: errorBinding) {
            Button("OK") {
                workspace.errorMessage = nil
            }
        } message: {
            Text(workspace.errorMessage ?? "An unknown machine error occurred.")
        }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            ProjectBrowserView(workspace: workspace)
            Divider()
                .overlay(Color.sectorBorder)
            workspaceContent
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            ProjectBrowserView(workspace: workspace, isCompact: true)
            Divider()
                .overlay(Color.sectorBorder)
            workspaceContent
        }
    }

    private var workspaceContent: some View {
        VStack(spacing: 16) {
            header
            emulatorContent
            footer
        }
        .padding(.horizontal, 28)
        .padding(.vertical, 20)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var header: some View {
        HStack(spacing: 12) {
            Text(workspace.currentProject?.projectName.uppercased() ?? "SECTOR ZERO")
                .font(.sectorMono(13, weight: .semibold))
                .tracking(2)
                .foregroundStyle(Color.sectorText)
            statusChip
            Spacer(minLength: 0)
            speedPicker
            breakpointButton
            boundedRunButton
            traceButton
            runPauseButton
            stepButton
            resetButton
        }
    }

    private var statusChip: some View {
        let condition = workspace.machineCondition
        let hue = Color.sectorStatus(condition.severity)
        return HStack(spacing: 6) {
            Circle()
                .fill(hue)
                .frame(width: 6, height: 6)
            Text(condition.label)
                .font(.sectorMono(10, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(hue)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .overlay {
            Capsule(style: .continuous)
                .stroke(hue.opacity(0.35), lineWidth: 1)
        }
        .help(workspace.machineConditionDetail ?? "Machine condition")
        .accessibilityIdentifier("machineStatusChip")
        .accessibilityLabel("Machine status: \(condition.label)")
    }

    private var speedPicker: some View {
        Menu {
            Picker("Run Speed", selection: $workspace.runSpeedCap) {
                ForEach(RunSpeedCap.allCases) { cap in
                    Text(cap.label).tag(cap)
                }
            }
        } label: {
            controlLabel("SPEED \(workspace.runSpeedCap.detailLabel)")
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .help("Cap run speed")
        .accessibilityIdentifier("runSpeedPicker")
    }

    private var runPauseButton: some View {
        Button {
            workspace.toggleRunPause()
        } label: {
            controlLabel(workspace.runButtonTitle, tint: workspace.isRunning ? .sectorRun : nil)
        }
        .buttonStyle(.plain)
        .keyboardShortcut("r", modifiers: .command)
        .help(workspace.isRunning
            ? "Pause at the next instruction boundary (⌘R)"
            : "Run the machine (⌘R)")
        .accessibilityIdentifier("runPauseButton")
    }

    private var breakpointButton: some View {
        Button {
            workspace.toggleBreakpointAtCurrentAddress()
        } label: {
            controlLabel("BP", tint: workspace.hasBreakpointAtCurrentAddress ? .sectorAccent : nil)
                .opacity(workspace.isRunning ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(workspace.isRunning)
        .help("Toggle a breakpoint at the current physical code address")
        .accessibilityIdentifier("breakpointButton")
    }

    private var boundedRunButton: some View {
        Button {
            workspace.runBounded(maxInstructions: 2_048)
        } label: {
            controlLabel("RUN 2K")
                .opacity(workspace.isRunning ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(workspace.isRunning)
        .help("Run at most 2,048 instruction boundaries")
        .accessibilityIdentifier("boundedRunButton")
    }

    private var traceButton: some View {
        Button {
            #if os(macOS)
            NSPasteboard.general.clearContents()
            NSPasteboard.general.setString(workspace.exportedInstructionTrace, forType: .string)
            #endif
        } label: {
            controlLabel("TRACE")
                .opacity(workspace.instructionTrace.isEmpty ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(workspace.instructionTrace.isEmpty)
        .help("Copy the deterministic instruction trace")
        .accessibilityIdentifier("traceExportButton")
    }

    private var stepButton: some View {
        Button {
            workspace.step()
        } label: {
            controlLabel("STEP")
                .opacity(workspace.isRunning ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(workspace.isRunning)
        .keyboardShortcut("t", modifiers: .command)
        .help("Fetch the next opcode at CS:IP (⌘T)")
        .accessibilityIdentifier("stepButton")
    }

    private var resetButton: some View {
        Button {
            workspace.resetMachine()
        } label: {
            controlLabel("RESET")
                .opacity(workspace.isRunning ? 0.4 : 1)
        }
        .buttonStyle(.plain)
        .disabled(workspace.isRunning)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help("Reset the CPU and devices to their power-on state (⇧⌘R)")
        .accessibilityIdentifier("resetButton")
    }

    private func controlLabel(_ title: String, tint: Color? = nil) -> some View {
        Text(title)
            .font(.sectorMono(11, weight: .semibold))
            .tracking(1.5)
            .foregroundStyle(tint ?? Color.sectorText)
            .padding(.horizontal, 14)
            .padding(.vertical, 6)
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(tint?.opacity(0.5) ?? Color.sectorBorder, lineWidth: 1)
            }
    }

    private var display: some View {
        ZStack {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.sectorPanel)

            CRTMetalView(video: workspace.machineSnapshot.video)
                .padding(10)
                .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
        }
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(Color.sectorBorder, lineWidth: 1)
                .allowsHitTesting(false)
            }
        #if os(macOS)
        .overlay {
            // Topmost so clicks reach it and focus keyboard capture.
            MachineKeyCaptureView(workspace: workspace)
        }
        .help("Click to send keystrokes to the machine")
        #endif
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .aspectRatio(4.0 / 3.0, contentMode: .fit)
        .layoutPriority(1)
    }

    @ViewBuilder
    private var emulatorContent: some View {
        if isCompact {
            VStack(spacing: 14) {
                display
                CPUInspectorView(state: workspace.machineSnapshot)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            HStack(alignment: .top, spacing: 16) {
                display
                CPUInspectorView(state: workspace.machineSnapshot)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 16) {
            Text(workspace.statusText)
                .font(.sectorMono(11))
                .tracking(1.4)
                .foregroundStyle(Color.sectorMutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            if let detail = workspace.machineConditionDetail {
                Text(detail)
                    .font(.sectorMono(11))
                    .tracking(1.4)
                    .foregroundStyle(Color.sectorStatus(workspace.machineCondition.severity))
                    .lineLimit(1)
                    .layoutPriority(1)
            }
        }
    }

    private var errorBinding: Binding<Bool> {
        Binding {
            workspace.errorMessage != nil
        } set: { isPresented in
            if !isPresented {
                workspace.errorMessage = nil
            }
        }
    }

    private var isCompact: Bool {
        horizontalSizeClass == .compact
    }
}

#Preview {
    SectorZeroWorkspaceView(workspace: SectorZeroWorkspace())
}
