import SwiftUI
import UniformTypeIdentifiers

#if os(macOS)
import AppKit
#endif

struct ProjectBrowserView: View {
    @Bindable var workspace: SectorZeroWorkspace
    var isCompact = false

    @State private var isShowingNewProject = false
    @State private var isShowingMachineEditor = false
    @State private var isImportingProject = false
    @State private var isImportingFirmware = false
    @State private var isImportingDiskImage = false
    @State private var diskSlotBeingImported: ProjectDiskSlot = .floppyA
    @State private var projectPendingDeletion: RecentProject?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 22) {
                brand
                primaryActions

                if let project = workspace.currentProject {
                    activeMachine(project)
                    machineSetup(project)
                } else {
                    noMachineCard
                }

                recentProjects
            }
            .padding(18)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .frame(width: isCompact ? nil : 284)
        .frame(maxWidth: isCompact ? .infinity : nil, maxHeight: .infinity, alignment: .topLeading)
        .background(Color.sectorSidebar)
        .sheet(isPresented: $isShowingNewProject) {
            NewProjectSheet(workspace: workspace)
        }
        .sheet(isPresented: $isShowingMachineEditor) {
            MachineEditorView(workspace: workspace)
        }
        .fileImporter(
            isPresented: $isImportingProject,
            allowedContentTypes: [.folder],
            allowsMultipleSelection: false,
            onCompletion: openImportedProject
        )
        .fileImporter(
            isPresented: $isImportingFirmware,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false,
            onCompletion: openImportedFirmware
        )
        .fileImporter(
            isPresented: $isImportingDiskImage,
            allowedContentTypes: [.data, .item],
            allowsMultipleSelection: false,
            onCompletion: openImportedDiskImage
        )
        .alert("Delete Machine?", isPresented: isConfirmingDeletion) {
            Button("Cancel", role: .cancel) {}
            Button("Delete", role: .destructive) {
                if let projectPendingDeletion {
                    workspace.deleteProject(projectPendingDeletion)
                }
            }
        } message: {
            Text("This permanently deletes \(projectPendingDeletion?.projectName ?? "this machine") and every file in its package.")
        }
    }

    private var brand: some View {
        HStack(spacing: 11) {
            ZStack {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(Color.sectorSelection)
                Image(systemName: "cpu")
                    .font(.system(size: 17, weight: .medium))
                    .foregroundStyle(Color.sectorRun)
            }
            .frame(width: 38, height: 38)
            .overlay {
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .stroke(Color.sectorStrongBorder, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 2) {
                Text("SECTOR ZERO")
                    .font(.sectorMono(13, weight: .bold))
                    .tracking(1.6)
                    .foregroundStyle(Color.sectorHeading)
                Text("8086 machine lab")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(Color.sectorMutedText)
            }
        }
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Sector Zero, 8086 machine lab")
    }

    private var primaryActions: some View {
        HStack(spacing: 8) {
            Button {
                isShowingNewProject = true
            } label: {
                Label("NEW", systemImage: "plus")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SectorToolbarButtonStyle(tint: .sectorRun, isProminent: true))
            .help("Create a new machine")
            .accessibilityIdentifier("newMachineButton")

            Button {
                openExistingProject()
            } label: {
                Label("OPEN", systemImage: "folder")
                    .frame(maxWidth: .infinity)
            }
            .buttonStyle(SectorToolbarButtonStyle())
            .help("Open an existing Sector Zero machine")
            .accessibilityIdentifier("openMachineButton")
        }
    }

    private func activeMachine(_ project: SectorZeroProject) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectorSectionLabel(title: "ACTIVE MACHINE", systemImage: "power")

            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "desktopcomputer")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(Color.sectorRun)
                    .frame(width: 24, height: 24)

                VStack(alignment: .leading, spacing: 4) {
                    Text(project.projectName)
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.sectorText)
                        .lineLimit(1)
                    Text(project.projectURL.deletingLastPathComponent().path)
                        .font(.sectorMono(10, weight: .regular))
                        .foregroundStyle(Color.sectorMutedText)
                        .lineLimit(2)
                        .truncationMode(.middle)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .padding(12)
            .sectorCard(fill: .sectorSelection)

            Button("Edit Machine…", systemImage: "slider.horizontal.3") {
                isShowingMachineEditor = true
            }
            .buttonStyle(.borderless)
            .disabled(workspace.isRunning)
            .accessibilityIdentifier("editMachineButton")
        }
    }

    private func machineSetup(_ project: SectorZeroProject) -> some View {
        VStack(alignment: .leading, spacing: 9) {
            SectorSectionLabel(title: "MACHINE SETUP", systemImage: "slider.horizontal.3")

            VStack(spacing: 0) {
                firmwareRow(for: project)
                Divider().overlay(Color.sectorBorder)
                diskImageRow(for: project)
                Divider().overlay(Color.sectorBorder)
                floppyBRow(for: project)
                Divider().overlay(Color.sectorBorder)
                hardDiskRow(for: project)
            }
            .sectorCard()
        }
    }

    private var noMachineCard: some View {
        VStack(alignment: .leading, spacing: 10) {
            SectorSectionLabel(title: "GET STARTED", systemImage: "sparkles")
            VStack(alignment: .leading, spacing: 7) {
                Text("No machine is open")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.sectorText)
                Text("Create a machine package or open one from disk to begin.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sectorMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .sectorCard()
        }
    }

    private var recentProjects: some View {
        VStack(alignment: .leading, spacing: 9) {
            SectorSectionLabel(title: "RECENT MACHINES", systemImage: "clock")

            if workspace.recentProjects.isEmpty {
                Text("Machines you open will stay within easy reach here.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sectorMutedText)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 2)
            } else {
                VStack(spacing: 4) {
                    ForEach(workspace.recentProjects) { project in
                        recentProjectRow(project)
                    }
                }
            }
        }
    }

    private func recentProjectRow(_ project: RecentProject) -> some View {
        let isActive = workspace.currentProject?.projectURL == project.projectURL
        return HStack(spacing: 6) {
            Button {
                workspace.openRecentProject(project)
            } label: {
                HStack(spacing: 9) {
                    Circle()
                        .fill(isActive ? Color.sectorRun : Color.sectorBorder)
                        .frame(width: 6, height: 6)

                    VStack(alignment: .leading, spacing: 3) {
                        Text(project.projectName)
                            .font(.system(size: 13, weight: isActive ? .semibold : .medium))
                            .foregroundStyle(Color.sectorText)
                        Text(project.projectURL.deletingLastPathComponent().path)
                            .font(.sectorMono(9, weight: .regular))
                            .foregroundStyle(Color.sectorMutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .padding(.leading, 10)
                .padding(.vertical, 8)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open \(project.projectName)")

            Menu {
                Button("Delete Machine", systemImage: "trash", role: .destructive) {
                    projectPendingDeletion = project
                }
            } label: {
                Image(systemName: "ellipsis")
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(Color.sectorMutedText)
                    .frame(width: 28, height: 28)
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Machine actions")
        }
        .padding(.trailing, 5)
        .background(isActive ? Color.sectorSelection : Color.clear)
        .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 7, style: .continuous)
                .stroke(isActive ? Color.sectorBorder : Color.clear, lineWidth: 1)
        }
    }

    private func firmwareRow(for project: SectorZeroProject) -> some View {
        setupRow(
            title: "Firmware",
            value: project.configuredFirmwareURL?.lastPathComponent ?? "Built-in BIOS available",
            systemImage: "memorychip",
            isMissing: project.configuredFirmwareURL == nil
        ) {
            if project.configuredFirmwareURL == nil {
                Button("Install BIOS") {
                    workspace.installBuiltInFirmware()
                }
                .controlSize(.small)
                .tint(Color.sectorRun)
                .disabled(workspace.isRunning)
                .help("Install Sector Zero’s clean-room BIOS")
                .accessibilityIdentifier("installBuiltInFirmwareButton")

                Button {
                    chooseFirmware()
                } label: {
                    Image(systemName: "folder")
                }
                .controlSize(.small)
                .tint(Color.sectorHeading)
                .disabled(workspace.isRunning)
                .help("Choose a custom ROM image")
                .accessibilityLabel("Choose custom firmware")
                .accessibilityIdentifier("chooseFirmwareButton")
            } else {
                Menu {
                    Button("Restore Built-in BIOS", systemImage: "memorychip") {
                        workspace.installBuiltInFirmware()
                    }
                    Button("Choose Custom ROM…", systemImage: "folder") {
                        chooseFirmware()
                    }
                } label: {
                    Image(systemName: "ellipsis")
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .disabled(workspace.isRunning)
                .help("Firmware options")
                .accessibilityIdentifier("chooseFirmwareButton")
            }
        }
    }

    private func diskImageRow(for project: SectorZeroProject) -> some View {
        setupRow(
            title: "Floppy A",
            value: project.configuredDiskImageURL?.lastPathComponent ?? "Empty",
            systemImage: "externaldrive",
            isMissing: project.configuredDiskImageURL == nil
        ) {
            if project.configuredDiskImageURL != nil {
                Button {
                    workspace.ejectDiskImage()
                } label: {
                    Image(systemName: "eject")
                }
                .controlSize(.small)
                .tint(Color.sectorHeading)
                .disabled(workspace.isRunning)
                .help("Eject the mounted floppy")
                .accessibilityLabel("Eject floppy")
                .accessibilityIdentifier("ejectDiskImageButton")
            }

            Button(project.configuredDiskImageURL == nil ? "Insert" : "Replace") {
                chooseDiskImage(slot: .floppyA)
            }
            .controlSize(.small)
            .tint(Color.sectorHeading)
            .disabled(workspace.isRunning)
            .help("Install a supported raw floppy image")
            .accessibilityIdentifier("chooseDiskImageButton")
        }
    }

    private func floppyBRow(for project: SectorZeroProject) -> some View {
        setupRow(
            title: "Floppy B",
            value: project.configuredFloppyBURL?.lastPathComponent ?? "Empty",
            systemImage: "externaldrive",
            isMissing: project.configuredFloppyBURL == nil
        ) {
            if project.configuredFloppyBURL != nil {
                Button { workspace.ejectFloppyDisk(drive: 1) } label: {
                    Image(systemName: "eject")
                }
                .controlSize(.small)
                .disabled(workspace.isRunning)
            }
            Button(project.configuredFloppyBURL == nil ? "Insert" : "Replace") {
                chooseDiskImage(slot: .floppyB)
            }
            .controlSize(.small)
            .disabled(workspace.isRunning)
        }
    }

    private func hardDiskRow(for project: SectorZeroProject) -> some View {
        setupRow(
            title: "Hard Disk C",
            value: project.configuredHardDiskURL?.lastPathComponent ?? "Empty",
            systemImage: "internaldrive",
            isMissing: project.configuredHardDiskURL == nil
        ) {
            if project.configuredHardDiskURL != nil {
                Button { workspace.ejectHardDisk() } label: { Image(systemName: "eject") }
                    .controlSize(.small)
                    .disabled(workspace.isRunning)
            } else {
                Button("Create 20 MB") { workspace.createBlankHardDisk() }
                    .controlSize(.small)
                    .disabled(workspace.isRunning)
            }
            Button(project.configuredHardDiskURL == nil ? "Attach" : "Replace") {
                chooseDiskImage(slot: .hardDisk)
            }
            .controlSize(.small)
            .disabled(workspace.isRunning)
        }
    }

    private func setupRow<Actions: View>(
        title: String,
        value: String,
        systemImage: String,
        isMissing: Bool,
        @ViewBuilder actions: () -> Actions
    ) -> some View {
        HStack(spacing: 9) {
            Image(systemName: systemImage)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(isMissing ? Color.sectorAccent : Color.sectorHeading)
                .frame(width: 20)

            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.sectorMutedText)
                Text(value)
                    .font(.sectorMono(10, weight: .regular))
                    .foregroundStyle(isMissing ? Color.sectorAccent : Color.sectorText)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            HStack(spacing: 4) {
                actions()
            }
        }
        .padding(10)
    }

    private func chooseFirmware() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Firmware Image"
        panel.prompt = "Install"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.configureFirmware(from: url)
        #else
        isImportingFirmware = true
        #endif
    }

    private func chooseDiskImage(slot: ProjectDiskSlot) {
        diskSlotBeingImported = slot
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = slot == .hardDisk ? "Choose Hard Disk Image" : "Choose Floppy Image"
        panel.prompt = slot == .hardDisk ? "Attach" : "Insert"
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        switch slot {
        case .floppyA: workspace.configureFloppyDisk(from: url, drive: 0)
        case .floppyB: workspace.configureFloppyDisk(from: url, drive: 1)
        case .hardDisk: workspace.configureHardDisk(from: url)
        }
        #else
        isImportingDiskImage = true
        #endif
    }

    private func openExistingProject() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Open Sector Zero Machine"
        panel.prompt = "Open"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK, let url = panel.url else { return }
        workspace.openProject(at: url)
        #else
        isImportingProject = true
        #endif
    }

    private func openImportedDiskImage(_ result: Result<[URL], Error>) {
        importSecurityScopedURL(from: result) { url in
            switch diskSlotBeingImported {
            case .floppyA: workspace.configureFloppyDisk(from: url, drive: 0)
            case .floppyB: workspace.configureFloppyDisk(from: url, drive: 1)
            case .hardDisk: workspace.configureHardDisk(from: url)
            }
        }
    }

    private func openImportedFirmware(_ result: Result<[URL], Error>) {
        importSecurityScopedURL(from: result) { workspace.configureFirmware(from: $0) }
    }

    private func openImportedProject(_ result: Result<[URL], Error>) {
        importSecurityScopedURL(from: result) { workspace.openProject(at: $0) }
    }

    private func importSecurityScopedURL(
        from result: Result<[URL], Error>,
        action: (URL) -> Void
    ) {
        switch result {
        case .success(let urls):
            guard let url = urls.first else { return }
            let didStartAccess = url.startAccessingSecurityScopedResource()
            defer {
                if didStartAccess { url.stopAccessingSecurityScopedResource() }
            }
            action(url)
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
        .frame(height: 760)
}
