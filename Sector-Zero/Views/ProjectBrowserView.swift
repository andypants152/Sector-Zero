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
    }

    private var title: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PROJECTS")
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
                Label("Create New Project", systemImage: "plus")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.borderedProminent)

            Button {
                openExistingProject()
            } label: {
                Label("Open Existing Project", systemImage: "folder")
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.bordered)
        }
    }

    @ViewBuilder
    private var currentProjectSummary: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("CURRENT PROJECT")
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
            } else {
                Text("No project open")
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
                Text("Recently opened projects will appear here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sectorMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                VStack(spacing: 6) {
                    ForEach(workspace.recentProjects) { project in
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
                    }
                }
            }
        }
    }

    private func openExistingProject() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Open Sector Zero Project"
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
}

#Preview {
    ProjectBrowserView(workspace: SectorZeroWorkspace())
}
