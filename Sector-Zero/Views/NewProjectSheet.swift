import SwiftUI

#if os(macOS)
import AppKit
#endif

struct NewProjectSheet: View {
    @Bindable var workspace: SectorZeroWorkspace
    @Environment(\.dismiss) private var dismiss

    @State private var projectName = ""
    @State private var destinationFolderURL: URL? = Self.defaultDestinationFolderURL

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            header
            fields
            actions
        }
        .padding(24)
        .frame(minWidth: 300, idealWidth: 460, maxWidth: 460)
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("New Project")
                .font(.title2.weight(.semibold))
            Text("Create a Sector Zero project package on disk.")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }

    private var fields: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Project Name")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                TextField("Project Name", text: $projectName)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 6) {
                Text("Destination Folder")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                HStack(spacing: 8) {
                    Text(destinationFolderURL?.path ?? "No folder selected")
                        .font(.system(size: 12, weight: .regular, design: .monospaced))
                        .foregroundStyle(destinationFolderURL == nil ? .secondary : .primary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)

                    #if os(macOS)
                    chooseDestinationButton
                    #endif
                }
            }
        }
    }

    private var chooseDestinationButton: some View {
        Button {
            chooseDestinationFolder()
        } label: {
            Label("Choose", systemImage: "folder")
        }
    }

    private var actions: some View {
        HStack {
            Spacer(minLength: 0)
            Button("Cancel") {
                dismiss()
            }
            Button {
                createProject()
            } label: {
                Label("Create", systemImage: "plus")
            }
            .buttonStyle(.borderedProminent)
            .disabled(!canCreateProject)
        }
    }

    private var canCreateProject: Bool {
        !projectName.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && destinationFolderURL != nil
    }

    private func chooseDestinationFolder() {
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.title = "Choose Project Destination"
        panel.prompt = "Choose"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false

        guard panel.runModal() == .OK else {
            return
        }

        destinationFolderURL = panel.url
        #else
        workspace.errorMessage = "Choosing a destination folder is only available on macOS."
        #endif
    }

    private func createProject() {
        guard let destinationFolderURL else {
            return
        }

        if workspace.createProject(named: projectName, in: destinationFolderURL) {
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
