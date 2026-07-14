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
        .frame(minWidth: 900, minHeight: 620)
        .background(Color.sectorWorkspace)
        .alert("Action Couldn’t Be Completed", isPresented: errorBinding) {
            Button("Dismiss") {
                workspace.errorMessage = nil
            }
        } message: {
            Text(workspace.errorMessage ?? "Sector Zero encountered an unknown error.")
        }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            ProjectBrowserView(workspace: workspace)
            Divider().overlay(Color.sectorBorder)
            workspaceContent
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            ProjectBrowserView(workspace: workspace, isCompact: true)
                .frame(maxHeight: workspace.currentProject == nil ? .infinity : 270)
            if workspace.currentProject != nil {
                Divider().overlay(Color.sectorBorder)
                workspaceContent
            }
        }
    }

    private var workspaceContent: some View {
        VStack(spacing: 14) {
            workspaceHeader

            if workspace.currentProject == nil {
                welcomeContent
            } else {
                readinessBanner
                emulatorContent
            }

            statusBar
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 18)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var workspaceHeader: some View {
        HStack(spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text(workspace.currentProject?.projectName ?? "Machine Workspace")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundStyle(Color.sectorText)
                    .lineLimit(1)
                Text(workspace.currentProject == nil ? "CREATE OR OPEN A MACHINE TO BEGIN" : "8086 • 640 KB • CGA")
                    .font(.sectorMono(9, weight: .semibold))
                    .tracking(1.3)
                    .foregroundStyle(Color.sectorMutedText)
            }

            if workspace.currentProject != nil {
                statusChip
            }

            Spacer(minLength: 8)

            if workspace.currentProject != nil {
                executionControls
            }
        }
        .frame(minHeight: 38)
    }

    private var executionControls: some View {
        HStack(spacing: 8) {
            speedPicker

            HStack(spacing: 4) {
                breakpointButton
                boundedRunButton
                traceButton
            }
            .padding(3)
            .sectorCard(cornerRadius: 9, fill: .sectorPanel)

            HStack(spacing: 4) {
                resetButton
                stepButton
                runPauseButton
            }
            .padding(3)
            .sectorCard(cornerRadius: 9, fill: .sectorPanel)
        }
    }

    private var statusChip: some View {
        let condition = workspace.machineCondition
        let hue = Color.sectorStatus(condition.severity)
        return HStack(spacing: 6) {
            Circle()
                .fill(hue)
                .frame(width: 7, height: 7)
                .shadow(color: condition.severity == .live ? hue.opacity(0.8) : .clear, radius: 4)
            Text(condition.label)
                .font(.sectorMono(9, weight: .bold))
                .tracking(1.2)
                .foregroundStyle(hue)
        }
        .padding(.horizontal, 9)
        .frame(height: 26)
        .background(hue.opacity(0.08))
        .clipShape(Capsule(style: .continuous))
        .overlay {
            Capsule(style: .continuous)
                .stroke(hue.opacity(0.35), lineWidth: 1)
        }
        .help(workspace.machineConditionDetail ?? "Machine is ready")
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
            Label(workspace.runSpeedCap.detailLabel.uppercased(), systemImage: "gauge.with.dots.needle.33percent")
        }
        .menuStyle(.button)
        .buttonStyle(SectorToolbarButtonStyle())
        .help("Run speed: \(workspace.runSpeedCap.label)")
        .accessibilityIdentifier("runSpeedPicker")
    }

    private var runPauseButton: some View {
        Button {
            workspace.toggleRunPause()
        } label: {
            Label(workspace.isRunning ? "PAUSE" : "RUN", systemImage: workspace.isRunning ? "pause.fill" : "play.fill")
        }
        .buttonStyle(SectorToolbarButtonStyle(tint: .sectorRun, isProminent: true))
        .disabled(!canExecute)
        .keyboardShortcut("r", modifiers: .command)
        .help(workspace.isRunning ? "Pause at the next instruction boundary (⌘R)" : "Run the machine (⌘R)")
        .accessibilityIdentifier("runPauseButton")
    }

    private var breakpointButton: some View {
        Button {
            workspace.toggleBreakpointAtCurrentAddress()
        } label: {
            Label("BP", systemImage: workspace.hasBreakpointAtCurrentAddress ? "smallcircle.filled.circle" : "smallcircle.circle")
        }
        .buttonStyle(SectorToolbarButtonStyle(tint: workspace.hasBreakpointAtCurrentAddress ? .sectorAccent : nil))
        .disabled(workspace.isRunning || !canExecute)
        .help("Toggle breakpoint at the current code address")
        .accessibilityIdentifier("breakpointButton")
    }

    private var boundedRunButton: some View {
        Button {
            workspace.runBounded(maxInstructions: 2_048)
        } label: {
            Label("2K", systemImage: "forward.frame")
        }
        .buttonStyle(SectorToolbarButtonStyle())
        .disabled(workspace.isRunning || !canExecute)
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
            Image(systemName: "doc.on.clipboard")
                .frame(width: 13)
                .accessibilityLabel("Copy trace")
        }
        .buttonStyle(SectorToolbarButtonStyle())
        .disabled(workspace.instructionTrace.isEmpty)
        .help("Copy the deterministic instruction trace")
        .accessibilityIdentifier("traceExportButton")
    }

    private var stepButton: some View {
        Button {
            workspace.step()
        } label: {
            Label("STEP", systemImage: "forward.end.fill")
        }
        .buttonStyle(SectorToolbarButtonStyle())
        .disabled(workspace.isRunning || !canExecute)
        .keyboardShortcut("t", modifiers: .command)
        .help("Execute the next instruction (⌘T)")
        .accessibilityIdentifier("stepButton")
    }

    private var resetButton: some View {
        Button {
            workspace.resetMachine()
        } label: {
            Image(systemName: "arrow.clockwise")
                .frame(width: 13)
                .accessibilityLabel("Reset")
        }
        .buttonStyle(SectorToolbarButtonStyle())
        .disabled(workspace.isRunning || !canExecute)
        .keyboardShortcut("r", modifiers: [.command, .shift])
        .help("Reset the CPU and devices (⇧⌘R)")
        .accessibilityIdentifier("resetButton")
    }

    @ViewBuilder
    private var readinessBanner: some View {
        if workspace.machineSnapshot.loadedSystemROMByteCount == 0 {
            HStack(spacing: 10) {
                Image(systemName: "memorychip")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.sectorAccent)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Firmware required")
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(Color.sectorText)
                    Text("Install Sector Zero’s built-in BIOS or choose a custom ROM.")
                        .font(.system(size: 11))
                        .foregroundStyle(Color.sectorMutedText)
                }
                Spacer(minLength: 0)
                Text("MACHINE SETUP → FIRMWARE")
                    .font(.sectorMono(9, weight: .semibold))
                    .tracking(0.8)
                    .foregroundStyle(Color.sectorAccent)
            }
            .padding(.horizontal, 13)
            .frame(minHeight: 48)
            .sectorCard(fill: Color.sectorAccent.opacity(0.06))
        }
    }

    private var emulatorContent: some View {
        HStack(alignment: .top, spacing: 14) {
            displayPanel
            CPUInspectorView(state: workspace.machineSnapshot)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var displayPanel: some View {
        VStack(spacing: 0) {
            HStack(spacing: 10) {
                SectorSectionLabel(title: "DISPLAY", systemImage: "rectangle.inset.filled")
                Text("CGA 80 × 25")
                    .font(.sectorMono(9, weight: .medium))
                    .foregroundStyle(Color.sectorMutedText)
                Spacer(minLength: 0)
                mediaIndicator
            }
            .padding(.horizontal, 13)
            .frame(height: 38)

            Divider().overlay(Color.sectorBorder)

            ZStack {
                Color.black.opacity(0.76)
                CRTMetalView(video: workspace.machineSnapshot.video)
                    .padding(12)
            }
            .overlay {
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(Color.sectorStrongBorder.opacity(0.5), lineWidth: 1)
                    .padding(8)
                    .allowsHitTesting(false)
            }
            #if os(macOS)
            .overlay {
                MachineKeyCaptureView(workspace: workspace)
            }
            .help("Click to direct keyboard input to the machine")
            #endif
            .aspectRatio(4.0 / 3.0, contentMode: .fit)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .layoutPriority(1)

            Divider().overlay(Color.sectorBorder)

            HStack(spacing: 8) {
                Image(systemName: "keyboard")
                    .foregroundStyle(Color.sectorHeading)
                Text("Click the display, then type to use the XT keyboard")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.sectorMutedText)
                Spacer(minLength: 0)
                Text("4:3")
                    .font(.sectorMono(9, weight: .semibold))
                    .foregroundStyle(Color.sectorMutedText)
            }
            .padding(.horizontal, 13)
            .frame(height: 38)
        }
        .sectorCard()
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Emulated CGA display")
    }

    private var mediaIndicator: some View {
        let hasMedia = workspace.machineSnapshot.floppyController.mediaGeometry != nil
        return HStack(spacing: 6) {
            Circle()
                .fill(hasMedia ? Color.sectorRun : Color.sectorBorder)
                .frame(width: 6, height: 6)
            Text(hasMedia ? "FLOPPY A" : "NO MEDIA")
                .font(.sectorMono(9, weight: .semibold))
                .tracking(0.7)
                .foregroundStyle(hasMedia ? Color.sectorHeading : Color.sectorMutedText)
        }
        .accessibilityLabel(hasMedia ? "Floppy A inserted" : "No floppy inserted")
    }

    private var welcomeContent: some View {
        VStack(spacing: 28) {
            Spacer(minLength: 12)

            VStack(spacing: 12) {
                ZStack {
                    Circle()
                        .fill(Color.sectorSelection)
                    Circle()
                        .stroke(Color.sectorStrongBorder, lineWidth: 1)
                    Image(systemName: "poweron")
                        .font(.system(size: 28, weight: .light))
                        .foregroundStyle(Color.sectorRun)
                }
                .frame(width: 68, height: 68)

                Text("Build a machine. Watch it come alive.")
                    .font(.system(size: 24, weight: .semibold))
                    .foregroundStyle(Color.sectorText)
                Text("Sector Zero is a focused 8086 lab for booting, inspecting, and debugging early PC software.")
                    .font(.system(size: 14))
                    .foregroundStyle(Color.sectorMutedText)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 560)
            }

            HStack(spacing: 12) {
                welcomeStep("1", title: "Create a machine", detail: "New machines include Sector Zero’s clean-room BIOS.", systemImage: "macwindow.badge.plus")
                welcomeStep("2", title: "Insert a floppy", detail: "Mount your own supported raw disk image.", systemImage: "externaldrive")
                welcomeStep("3", title: "Run and inspect", detail: "Boot, step the CPU, and follow machine state live.", systemImage: "play.rectangle")
            }
            .frame(maxWidth: 720)

            HStack(spacing: 7) {
                Image(systemName: "arrow.left")
                Text("Create or open a machine in the sidebar")
            }
            .font(.sectorMono(10, weight: .semibold))
            .tracking(0.6)
            .foregroundStyle(Color.sectorAccent)

            Spacer(minLength: 12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(28)
        .sectorCard(fill: Color.sectorSidebar.opacity(0.55))
    }

    private func welcomeStep(_ number: String, title: String, detail: String, systemImage: String) -> some View {
        VStack(alignment: .leading, spacing: 13) {
            HStack {
                Text(number)
                    .font(.sectorMono(10, weight: .bold))
                    .foregroundStyle(Color.sectorRun)
                    .frame(width: 24, height: 24)
                    .background(Color.sectorSelection)
                    .clipShape(Circle())
                Spacer(minLength: 0)
                Image(systemName: systemImage)
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.sectorHeading)
            }
            Text(title)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.sectorText)
            Text(detail)
                .font(.system(size: 11))
                .foregroundStyle(Color.sectorMutedText)
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(14)
        .frame(maxWidth: .infinity, minHeight: 132, alignment: .topLeading)
        .sectorCard(fill: .sectorPanel)
    }

    private var statusBar: some View {
        HStack(spacing: 12) {
            Image(systemName: workspace.currentProject == nil ? "tray" : "shippingbox")
                .font(.system(size: 11, weight: .medium))
                .foregroundStyle(Color.sectorMutedText)
            Text(statusPath)
                .font(.sectorMono(9, weight: .regular))
                .foregroundStyle(Color.sectorMutedText)
                .lineLimit(1)
                .truncationMode(.middle)

            Spacer(minLength: 0)

            if workspace.currentProject != nil {
                Text("CYC \(workspace.machineSnapshot.cycleCount)")
                    .font(.sectorMono(9, weight: .semibold))
                    .foregroundStyle(Color.sectorMutedText)
                if let detail = workspace.machineConditionDetail {
                    Divider().frame(height: 12).overlay(Color.sectorBorder)
                    Text(detail)
                        .font(.system(size: 10, weight: .medium))
                        .foregroundStyle(Color.sectorStatus(workspace.machineCondition.severity))
                        .lineLimit(1)
                }
            }
        }
        .padding(.horizontal, 10)
        .frame(height: 28)
        .background(Color.sectorSidebar.opacity(0.7))
        .clipShape(RoundedRectangle(cornerRadius: 6, style: .continuous))
    }

    private var statusPath: String {
        workspace.currentProject?.projectURL.path ?? "No machine open"
    }

    private var canExecute: Bool {
        workspace.machineSnapshot.loadedSystemROMByteCount > 0
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
        .frame(width: 1280, height: 800)
}
