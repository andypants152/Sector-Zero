import SwiftUI

#if os(macOS)
import AppKit
#else
import UIKit
#endif

struct NewProjectSheet: View {
    @Bindable var workspace: SectorZeroWorkspace
    @Environment(\.dismiss) private var dismiss

    @State private var projectName = ""
    @State private var destinationFolderURL: URL?
    @State private var floppyAURL: URL?
    @State private var floppyBURL: URL?
    @State private var hardDiskURL: URL?
    @State private var createsBlankHardDisk = false
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.sectorBorder)
            form
            Divider().overlay(Color.sectorBorder)
            actions
        }
        #if os(macOS)
        .frame(width: 500)
        #endif
        .background(Color.sectorWorkspace)
        .onAppear {
            isNameFocused = true
            if destinationFolderURL == nil {
                destinationFolderURL = workspace.libraryFolderURL
            }
        }
    }

    private var header: some View {
        HStack(spacing: 13) {
            ZStack {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .fill(Color.sectorSelection)
                Image(systemName: "macwindow.badge.plus")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.sectorRun)
            }
            .frame(width: 44, height: 44)
            .overlay {
                RoundedRectangle(cornerRadius: 9, style: .continuous)
                    .stroke(Color.sectorStrongBorder, lineWidth: 1)
            }

            VStack(alignment: .leading, spacing: 3) {
                Text("Create Machine")
                    .font(.system(size: 19, weight: .semibold))
                    .foregroundStyle(Color.sectorText)
                Text("Set up a new Sector Zero machine package.")
                    .font(.system(size: 12))
                    .foregroundStyle(Color.sectorMutedText)
            }
            Spacer(minLength: 0)
        }
        .padding(22)
    }

    private var form: some View {
        VStack(alignment: .leading, spacing: 20) {
            VStack(alignment: .leading, spacing: 8) {
                SectorSectionLabel(title: "MACHINE NAME", systemImage: "desktopcomputer")
                TextField("e.g. My 8086", text: $projectName)
                    .textFieldStyle(.plain)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundStyle(Color.sectorText)
                    .padding(.horizontal, 12)
                    .frame(height: 38)
                    .background(Color.sectorElevated)
                    .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: 7, style: .continuous)
                            .stroke(isNameFocused ? Color.sectorRun.opacity(0.7) : Color.sectorBorder, lineWidth: 1)
                    }
                    .focused($isNameFocused)
                    .onSubmit(createProject)
                    .accessibilityIdentifier("machineNameField")
            }

            VStack(alignment: .leading, spacing: 9) {
                SectorSectionLabel(title: "INITIAL DRIVES", systemImage: "internaldrive")
                Text("Choose media now, or leave any drive empty and manage it later.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.sectorMutedText)
                creationDriveRow("Floppy A", icon: "externaldrive", url: $floppyAURL, action: "Insert")
                creationDriveRow("Floppy B", icon: "externaldrive", url: $floppyBURL, action: "Insert")
                HStack(spacing: 10) {
                    Image(systemName: "internaldrive")
                        .foregroundStyle(Color.sectorHeading)
                        .frame(width: 18)
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Hard Disk C").font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.sectorText)
                        Text(hardDiskURL?.lastPathComponent ?? (createsBlankHardDisk ? "New blank 20 MB disk" : "Empty"))
                            .font(.sectorMono(10, weight: .regular)).foregroundStyle(Color.sectorMutedText).lineLimit(1)
                    }
                    Spacer()
                    if hardDiskURL == nil {
                        Toggle("20 MB", isOn: $createsBlankHardDisk).toggleStyle(.checkbox).controlSize(.small)
                    }
                    Button(hardDiskURL == nil ? "Attach" : "Clear") {
                        if hardDiskURL == nil { chooseMedia { hardDiskURL = $0; createsBlankHardDisk = false } } else { hardDiskURL = nil }
                    }.controlSize(.small)
                }
                .padding(10).sectorCard(fill: .sectorElevated)
            }

            VStack(alignment: .leading, spacing: 8) {
                SectorSectionLabel(title: "SAVE LOCATION", systemImage: "folder")
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.sectorHeading)
                    VStack(alignment: .leading, spacing: 2) {
                        #if os(macOS)
                        Text(destinationFolderURL?.lastPathComponent ?? "No folder selected")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.sectorText)
                        Text(destinationFolderURL?.path ?? "Choose where to save this machine")
                            .font(.sectorMono(9, weight: .regular))
                            .foregroundStyle(Color.sectorMutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        #else
                        Text(deviceLocationName)
                            .font(.system(size: 13, weight: .semibold))
                            .foregroundStyle(Color.sectorText)
                        Text("Saved in Sector Zero’s Documents")
                            .font(.system(size: 11))
                            .foregroundStyle(Color.sectorMutedText)
                        #endif
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    #if os(macOS)
                    Button("Choose…") {
                        chooseDestinationFolder()
                    }
                    .controlSize(.small)
                    .accessibilityIdentifier("chooseMachineDestinationButton")
                    #endif
                }
                .padding(12)
                .sectorCard(fill: .sectorElevated)
            }

            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "info.circle")
                    .foregroundStyle(Color.sectorAccent)
                Text("Sector Zero’s clean-room BIOS is installed automatically. You can replace it with a custom ROM and add floppy media after creation.")
                    .font(.system(size: 11))
                    .foregroundStyle(Color.sectorMutedText)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(12)
            .sectorCard(fill: Color.sectorAccent.opacity(0.05))
        }
        .padding(22)
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Text(packageNamePreview)
                .font(.sectorMono(9, weight: .regular))
                .foregroundStyle(Color.sectorMutedText)
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 0)
            Button("Cancel", role: .cancel) {
                dismiss()
            }
            .keyboardShortcut(.cancelAction)

            Button {
                createProject()
            } label: {
                Label("Create Machine", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.sectorRun)
            .keyboardShortcut(.defaultAction)
            .disabled(!canCreateProject)
            .accessibilityIdentifier("createMachineButton")
        }
        .padding(.horizontal, 22)
        .padding(.vertical, 16)
        .background(Color.sectorSidebar)
    }

    private var canCreateProject: Bool {
        !trimmedProjectName.isEmpty && destinationFolderURL != nil && workspace.libraryFolderURL != nil
    }

    private var trimmedProjectName: String {
        projectName.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var packageNamePreview: String {
        guard !trimmedProjectName.isEmpty else { return "Creates a .szm package" }
        return "\(trimmedProjectName).szm"
    }

    private func chooseDestinationFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Machine Destination"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = workspace.libraryFolderURL ?? Self.defaultDestinationFolderURL

        guard panel.runModal() == .OK else { return }
        guard let url = panel.url else { return }
        guard workspace.setLibraryFolder(url) else { return }
        destinationFolderURL = url
        #else
        workspace.errorMessage = "Choosing a destination folder is only available on macOS."
        #endif
    }

    private func createProject() {
        guard canCreateProject, let destinationFolderURL else { return }
        guard workspace.setLibraryFolder(destinationFolderURL) else { return }
        // URLs returned by NSOpenPanel are security scoped in the sandbox. The
        // scope must remain open for the complete package-creation transaction,
        // not merely while the picker itself is visible.
        let scopedURLs = [destinationFolderURL, floppyAURL, floppyBURL, hardDiskURL].compactMap { $0 }
        let accessedURLs = scopedURLs.filter { $0.startAccessingSecurityScopedResource() }
        defer { accessedURLs.forEach { $0.stopAccessingSecurityScopedResource() } }
        if workspace.createProject(named: trimmedProjectName, in: destinationFolderURL, floppyAURL: floppyAURL, floppyBURL: floppyBURL, hardDiskURL: hardDiskURL, createBlankHardDisk: createsBlankHardDisk) {
            dismiss()
        }
    }

    private func creationDriveRow(_ title: String, icon: String, url: Binding<URL?>, action: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: icon).foregroundStyle(Color.sectorHeading).frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(.system(size: 12, weight: .semibold)).foregroundStyle(Color.sectorText)
                Text(url.wrappedValue?.lastPathComponent ?? "Empty").font(.sectorMono(10, weight: .regular)).foregroundStyle(Color.sectorMutedText).lineLimit(1)
            }
            Spacer()
            Button(url.wrappedValue == nil ? action : "Clear") {
                if url.wrappedValue == nil { chooseMedia { url.wrappedValue = $0 } } else { url.wrappedValue = nil }
            }.controlSize(.small)
        }
        .padding(10).sectorCard(fill: .sectorElevated)
    }

    private func chooseMedia(_ completion: @escaping (URL) -> Void) {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Disk Image"; panel.prompt = "Choose"; panel.canChooseDirectories = false; panel.allowsMultipleSelection = false
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
        #endif
    }

    private static var defaultDestinationFolderURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }

    #if os(iOS)
    private var deviceLocationName: String {
        UIDevice.current.userInterfaceIdiom == .pad ? "On My iPad" : "On My iPhone"
    }
    #endif
}

#Preview {
    NewProjectSheet(workspace: SectorZeroWorkspace())
}
