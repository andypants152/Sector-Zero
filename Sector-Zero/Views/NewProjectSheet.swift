import SwiftUI

#if os(macOS)
import AppKit
#endif

struct NewProjectSheet: View {
    @Bindable var workspace: SectorZeroWorkspace
    @Environment(\.dismiss) private var dismiss

    @State private var projectName = ""
    @State private var destinationFolderURL: URL? = Self.defaultDestinationFolderURL
    @FocusState private var isNameFocused: Bool

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider().overlay(Color.sectorBorder)
            form
            Divider().overlay(Color.sectorBorder)
            actions
        }
        .frame(width: 500)
        .background(Color.sectorWorkspace)
        .onAppear {
            isNameFocused = true
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

            VStack(alignment: .leading, spacing: 8) {
                SectorSectionLabel(title: "SAVE LOCATION", systemImage: "folder")
                HStack(spacing: 10) {
                    Image(systemName: "folder.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Color.sectorHeading)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(destinationFolderURL?.lastPathComponent ?? "No folder selected")
                            .font(.system(size: 12, weight: .semibold))
                            .foregroundStyle(Color.sectorText)
                        Text(destinationFolderURL?.path ?? "Choose where to save this machine")
                            .font(.sectorMono(9, weight: .regular))
                            .foregroundStyle(Color.sectorMutedText)
                            .lineLimit(1)
                            .truncationMode(.middle)
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
        !trimmedProjectName.isEmpty && destinationFolderURL != nil
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

        guard panel.runModal() == .OK else { return }
        destinationFolderURL = panel.url
        #else
        workspace.errorMessage = "Choosing a destination folder is only available on macOS."
        #endif
    }

    private func createProject() {
        guard canCreateProject, let destinationFolderURL else { return }
        if workspace.createProject(named: trimmedProjectName, in: destinationFolderURL) {
            dismiss()
        }
    }

    private static var defaultDestinationFolderURL: URL? {
        FileManager.default.urls(for: .documentDirectory, in: .userDomainMask).first
    }
}

#Preview {
    NewProjectSheet(workspace: SectorZeroWorkspace())
}
