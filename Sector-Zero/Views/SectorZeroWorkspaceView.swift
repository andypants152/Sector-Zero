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
        HStack {
            Text(workspace.currentProject?.projectName.uppercased() ?? "SECTOR ZERO")
                .font(.sectorMono(13, weight: .semibold))
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
                .font(.sectorMono(11, weight: .semibold))
                .tracking(1.5)
                .foregroundStyle(Color.sectorText)
                .padding(.horizontal, 14)
                .padding(.vertical, 6)
                .overlay {
                    RoundedRectangle(cornerRadius: 6, style: .continuous)
                        .stroke(Color.sectorBorder, lineWidth: 1)
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
                    .stroke(Color.sectorBorder, lineWidth: 1)
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
                .font(.sectorMono(11))
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

#Preview {
    SectorZeroWorkspaceView(workspace: SectorZeroWorkspace())
}
