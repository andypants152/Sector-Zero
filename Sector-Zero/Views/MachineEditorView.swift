import SwiftUI
import UniformTypeIdentifiers

/// The editor owns machine identity and its portable media library. Every
/// imported floppy is copied into `<machine>.szm/disk`, so inserts below never
/// depend on the original file still being available on the host.
struct MachineEditorView: View {
    @Bindable var workspace: SectorZeroWorkspace
    @Environment(\.dismiss) private var dismiss

    @State private var name = ""
    @State private var images: [URL] = []
    @State private var isImporting = false
    @State private var imagePendingDeletion: URL?

    var body: some View {
        NavigationStack {
            Form {
                Section("MACHINE") {
                    TextField("Machine name", text: $name)
                        .accessibilityIdentifier("machineEditorName")
                    LabeledContent("Package") {
                        Text(workspace.currentProject?.projectURL.lastPathComponent ?? "—")
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                }

                Section {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text("Floppy media store")
                            Text("Images are copied into this machine’s package and can be reused in either drive.")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button("Import…", systemImage: "square.and.arrow.down") { isImporting = true }
                            .disabled(workspace.isRunning)
                            .accessibilityIdentifier("importFloppyToStoreButton")
                    }
                } header: {
                    Text("FLOPPIES")
                }

                Section {
                    if images.isEmpty {
                        ContentUnavailableView("No stored floppy images", systemImage: "externaldrive", description: Text("Import a raw floppy image to add it to this machine."))
                    } else {
                        ForEach(images, id: \.self) { imageURL in
                            floppyRow(imageURL)
                        }
                    }
                }

                Section("DRIVES") {
                    driveRow("Floppy A", image: workspace.currentProject?.configuredDiskImageURL, drive: 0)
                    driveRow("Floppy B", image: workspace.currentProject?.configuredFloppyBURL, drive: 1)
                }
            }
            .formStyle(.grouped)
            .navigationTitle("Edit Machine")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Done") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        if workspace.renameCurrentProject(to: name) { dismiss() }
                    }
                    .disabled(name.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || workspace.isRunning)
                }
            }
        }
        .frame(minWidth: 560, minHeight: 520)
        .onAppear {
            name = workspace.currentProject?.projectName ?? ""
            refreshImages()
        }
        .fileImporter(isPresented: $isImporting, allowedContentTypes: [.data, .item], allowsMultipleSelection: false) { result in
            guard case .success(let urls) = result, let url = urls.first else { return }
            let accessed = url.startAccessingSecurityScopedResource()
            defer { if accessed { url.stopAccessingSecurityScopedResource() } }
            if workspace.importFloppyToStore(from: url) { refreshImages() }
        }
        .alert("Remove Stored Floppy?", isPresented: deletionBinding) {
            Button("Cancel", role: .cancel) {}
            Button("Remove", role: .destructive) {
                if let imagePendingDeletion, workspace.removeStoredDiskImage(at: imagePendingDeletion) {
                    refreshImages()
                }
            }
        } message: {
            Text("This removes the package copy. If it is in a drive, it will be ejected first.")
        }
    }

    private func floppyRow(_ imageURL: URL) -> some View {
        HStack(spacing: 12) {
            Image(systemName: "externaldrive")
                .foregroundStyle(Color.sectorHeading)
            VStack(alignment: .leading, spacing: 2) {
                Text(imageURL.lastPathComponent)
                Text(imageSize(imageURL))
                    .font(.caption.monospaced())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Menu("Insert") {
                Button("Floppy A") { _ = workspace.mountStoredFloppyDisk(at: imageURL, drive: 0) }
                Button("Floppy B") { _ = workspace.mountStoredFloppyDisk(at: imageURL, drive: 1) }
            }
            .disabled(workspace.isRunning)
            Button(role: .destructive) { imagePendingDeletion = imageURL } label: {
                Image(systemName: "trash")
            }
            .disabled(workspace.isRunning)
            .accessibilityLabel("Remove \(imageURL.lastPathComponent)")
        }
    }

    private func driveRow(_ title: String, image: URL?, drive: UInt8) -> some View {
        HStack {
            Label(title, systemImage: "externaldrive")
            Spacer()
            Text(image?.lastPathComponent ?? "Empty")
                .foregroundStyle(image == nil ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.middle)
            if image != nil {
                Button("Eject") { _ = workspace.ejectFloppyDisk(drive: drive) }
                    .disabled(workspace.isRunning)
            }
        }
    }

    private func imageSize(_ url: URL) -> String {
        let bytes = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
        return ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func refreshImages() {
        images = workspace.storedDiskImages()
    }

    private var deletionBinding: Binding<Bool> {
        Binding { imagePendingDeletion != nil } set: { if !$0 { imagePendingDeletion = nil } }
    }
}
