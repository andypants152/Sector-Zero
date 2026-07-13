//
//  SectorZeroWorkspaceView.swift
//  Sector-Zero
//
//  Created by Andy Meyer on 7/12/26.
//

import SwiftUI

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
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color.sectorWorkspace)
        .alert("Project Error", isPresented: errorBinding) {
            Button("OK") {
                workspace.errorMessage = nil
            }
        } message: {
            Text(workspace.errorMessage ?? "An unknown project error occurred.")
        }
    }

    private var regularLayout: some View {
        HStack(spacing: 0) {
            ProjectBrowserView(workspace: workspace)
            Divider()
                .overlay(Color.sectorScreenBorder)
            workspaceContent
        }
    }

    private var compactLayout: some View {
        VStack(spacing: 0) {
            ProjectBrowserView(workspace: workspace, isCompact: true)
            Divider()
                .overlay(Color.sectorScreenBorder)
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
        HStack {
            Text(workspace.currentProject?.projectName.uppercased() ?? "SECTOR ZERO")
                .font(.system(size: 13, weight: .semibold, design: .monospaced))
                .tracking(2)
                .foregroundStyle(Color.sectorText)
            Spacer(minLength: 0)
            stepButton
        }
    }

    private var stepButton: some View {
        Button {
            workspace.step()
        } label: {
            Text("STEP")
                .font(.system(size: 11, weight: .semibold, design: .monospaced))
                .tracking(1.5)
                .foregroundStyle(Color.sectorText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.sectorScreenBorder, lineWidth: 1)
                }
        }
        .buttonStyle(.plain)
        .help("Fetch the next opcode at CS:IP")
    }

    private var display: some View {
        CRTMetalView()
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color.sectorScreenBorder, lineWidth: 1)
            }
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
        HStack {
            Text(workspace.statusText)
                .font(.system(size: 11, weight: .medium, design: .monospaced))
                .tracking(1.4)
                .foregroundStyle(Color.sectorMutedText)
            Spacer(minLength: 0)
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

private extension Color {
    static let sectorWorkspace = Color(red: 0.015, green: 0.017, blue: 0.016)
    static let sectorText = Color(red: 0.70, green: 0.82, blue: 0.72)
    static let sectorMutedText = Color(red: 0.34, green: 0.46, blue: 0.38)
    static let sectorScreenBorder = Color(red: 0.10, green: 0.18, blue: 0.13)
}

#Preview {
    SectorZeroWorkspaceView(workspace: SectorZeroWorkspace())
}
