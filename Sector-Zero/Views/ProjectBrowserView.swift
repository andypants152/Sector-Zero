import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

struct ProjectBrowserView: View {
    @Bindable var workspace: SectorZeroWorkspace
    var isCompact = false

    @State private var isShowingNewProject = false
    @State private var isImportingProject = false
    @State private var isImportingFirmware = false
    @State private var projectPendingDeletion: RecentProject?

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            title
            actions
            currentProjectSummary
            recentProjects
            if !isCompact {
                Spacer(minLength: 0)
            }
        }
        .padding(18)
        .frame(width: isCompact ? nil : 286, alignment: .topLeading)
        .frame(maxWidth: isCompact ? .infinity : nil, alignment: .topLeading)
        .frame(maxHeight: isCompact ? nil : .infinity, alignment: .topLeading)
        .background(Color.sectorSidebar)
        .sheet(isPresented: $isShowingNewProject) {
            NewProjectSheet(workspace: workspace)
        }
        .fileImporter(
            isPresented: $isImportingProject,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false
        ) { result in
            openImportedProject(result)
        }
        .alert("Delete Machine?", isPresented: isConfirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let projectPendingDeletion {
                    workspace.deleteProject(projectPendingDeletion)
                }
            }
        } message: {
            Text("This will permanently delete \(projectPendingDeletion?.projectName ?? "this machine") and its files.")
        }
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("MACHINES")
                .font(.sectorMono(12, weight: .semibold))
                .tracking(1.8)
                .foregroundStyle(Color.sectorMutedText)
            Text("Sector Zero")
                .font(.system(size: 22, weight: .semibold, design: .default))
                .foregroundStyle(Color.sectorText)
        }
    }

    private var actions: some View {
        VStack(spacing: 8) {
            Button {
                isShowingNewProject = true
            } label: {
                Label("Create New Machine", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)

            Button {
                openExistingProject()
            } label: {
                Label("Open Existing Machine", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var currentProjectSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CURRENT MACHINE")
                .font(.sectorMono(11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.sectorMutedText)

            if let project = workspace.currentProject {
                VStack(alignment: .leading, spacing: 3) {
                    Text(project.projectName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.sectorText)
                    Text(project.projectURL.deletingLastPathComponent().path)
                        .font(.sectorMono(11, weight: .regular))
                        .foregroundStyle(Color.sectorMutedText)
                        .lineLimit(2)
                }
                firmwareRow(for: project)
            } else {
                Text("No machine open")
                    .font(.system(size: 13))
                    .foregroundStyle(Color.sectorMutedText)
            }
        }
        .padding(.top, 4)
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("RECENT")
                .font(.sectorMono(11, weight: .semibold))
                .tracking(1.2)
                .foregroundStyle(Color.sectorMutedText)

            if workspace.recentProjects.isEmpty {
                Text("Recently opened machines will appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sectorMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(workspace.recentProjects) { project in
                        HStack(spacing: 8) {
                            Button {
                                workspace.openRecentProject(project)
                            } label: {
                                VStack(alignment: .leading, spacing: 3) {
                                    Text(project.projectName)
                                        .font(.system(size: 13, weight: .medium))
                                        .foregroundStyle(Color.sectorText)
                                    Text(project.projectURL.deletingLastPathComponent().path)
                                        .font(.sectorMono(10, weight: .regular))
                                        .foregroundStyle(Color.sectorMutedText)
                                        .lineLimit(1)
                                }
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .padding(.vertical, 6)
                            }
                            .buttonStyle(.plain)

                            Button(role: .destructive) {
                                projectPendingDeletion = project
                            } label: {
                                Image(systemName: "trash")
                                    .font(.system(size: 12, weight: .semibold))
                                    .frame(width: 28, height: 28)
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(Color.sectorMutedText)
                            .help("Delete machine")
                        }
                    }
                }
            }
        }
    }

    private func firmwareRow(for project: SectorZeroProject) -> some View {
        HStack(alignment: .center, spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text("FIRMWARE")
                    .font(.sectorMono(10, weight: .semibold))
                    .tracking(1.2)
                    .foregroundStyle(Color.sectorMutedText)
                Text(project.configuredFirmwareURL?.lastPathComponent ?? "None installed")
                    .font(.sectorMono(11, weight: .regular))
                    .foregroundStyle(project.configuredFirmwareURL == nil ? Color.sectorAccent : Color.sectorText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                chooseFirmware()
            } label: {
                Label("Choose", systemImage: "memorychip")
            }
            .controlSize(.small)
            .disabled(workspace.isRunning)
            .help("Install a ROM image (1–64 KiB, loaded at the top of the F0000h segment)")
            .accessibilityIdentifier("chooseFirmwareButton")
        }
        .padding(.top, 2)
        .fileImporter(
            isPresented: $isImportingFirmware,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false
        ) { result in
            openImportedFirmware(result)
        }
    }

    private func chooseFirmware() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Firmware Image"
        panel.prompt = "Choose"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        workspace.configureFirmware(from: url)
        #else
        isImportingFirmware = true
        #endif
    }

    private func openImportedFirmware(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }

            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            workspace.configureFirmware(from: url)
        case .failure(let error):
            workspace.errorMessage = error.localizedDescription
        }
    }

    private func openExistingProject() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Open Sector Zero Machine"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else {
            return
        }

        workspace.openProject(at: url)
        #else
        isImportingProject = true
        #endif
    }

    private func openImportedProject(_ result: Result<[URL], Error>) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else {
                return
            }

            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess {
                    url.stopAccessingSecurityScopedResource()
                }
            }
            workspace.openProject(at: url)
        case .failure(let error):
            workspace.errorMessage = error.localizedDescription
        }
    }

    private var isConfirmingDeletion: Binding<Bool> {
        Binding {
            projectPendingDeletion != nil
        } set: { isPresented in
            if !isPresented {
                projectPendingDeletion = nil
            }
        }
    }
}

#Preview {
    ProjectBrowserView(workspace: SectorZeroWorkspace())
}
