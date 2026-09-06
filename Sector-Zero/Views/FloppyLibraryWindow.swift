import SwiftUI

#if os(macOS)
import AppKit

struct FloppyLibraryWindow: View {
    @Bindable var workspace: SectorZeroWorkspace
    @State private var images: [URL] = []
    @State private var selectedImage: URL?
    @State private var files: [FAT12Floppy.Entry] = []
    @State private var selectedFile: FAT12Floppy.Entry?
    @State private var supportsFileTransfer = false
    @State private var isNamingBlank = false
    @State private var blankName = "Untitled Floppy.img"

    var body: some View {
        NavigationSplitView {
            List(images, id: \.self, selection: $selectedImage) { image in
                Label(image.lastPathComponent, systemImage: "externaldrive")
                    .tag(image)
            }
            .navigationTitle("Floppy Library")
            .toolbar {
                Button("New Blank", systemImage: "plus") { isNamingBlank = true }.disabled(workspace.currentProject == nil || workspace.isRunning)
                Button("Import Image…", systemImage: "square.and.arrow.down") { importImage() }.disabled(workspace.currentProject == nil || workspace.isRunning)
            }
        } detail: {
            if let selectedImage {
                VStack(alignment: .leading, spacing: 0) {
                    HStack {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(selectedImage.lastPathComponent).font(.title3.weight(.semibold))
                            Text("FAT12 1.44 MB floppy").foregroundStyle(.secondary)
                        }
                        Spacer()
                        Menu("Insert") {
                            Button("Floppy A") { _ = workspace.mountStoredFloppyDisk(at: selectedImage, drive: 0) }
                            Button("Floppy B") { _ = workspace.mountStoredFloppyDisk(at: selectedImage, drive: 1) }
                        }.disabled(workspace.isRunning)
                    }.padding()
                    Divider()
                    if supportsFileTransfer {
                        List(files, selection: $selectedFile) { file in
                            HStack { Image(systemName: "doc"); Text(file.name); Spacer(); Text(ByteCountFormatter.string(fromByteCount: Int64(file.byteCount), countStyle: .file)).foregroundStyle(.secondary) }
                                .tag(file)
                        }
                    } else {
                        ContentUnavailableView(
                            "File Transfer Unavailable",
                            systemImage: "externaldrive.badge.xmark",
                            description: Text("This is a valid raw floppy image, but it is not a DOS-formatted 1.44 MB FAT12 disk. You can still insert it into either drive. Create a new blank floppy to transfer files.")
                        )
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                    Divider()
                    HStack {
                        Button("Add Files…", systemImage: "plus") { addFiles(to: selectedImage) }.disabled(workspace.isRunning || !supportsFileTransfer)
                        Button("Export Selected…", systemImage: "square.and.arrow.up") { exportSelected(from: selectedImage) }.disabled(selectedFile == nil || !supportsFileTransfer)
                        Spacer()
                        Button("Remove Disk", role: .destructive) { if workspace.removeStoredDiskImage(at: selectedImage) { refresh() } }.disabled(workspace.isRunning)
                    }.padding()
                }
            } else {
                ContentUnavailableView("Choose a Floppy", systemImage: "externaldrive", description: Text("Create a blank DOS-formatted disk or import an existing raw image."))
            }
        }
        .frame(minWidth: 760, minHeight: 500)
        .onAppear(perform: refresh)
        .onChange(of: selectedImage) { _, _ in refreshFiles() }
        .alert("New Blank Floppy", isPresented: $isNamingBlank) {
            TextField("Disk name", text: $blankName)
            Button("Cancel", role: .cancel) {}
            Button("Create") { if let image = workspace.createBlankFloppy(named: blankName) { refresh(); selectedImage = image } }
        } message: { Text("Creates a DOS-formatted 1.44 MB FAT12 image in this machine’s media library.") }
    }

    private func refresh() { images = workspace.storedFloppyImages(); if selectedImage == nil || !images.contains(selectedImage!) { selectedImage = images.first }; refreshFiles() }
    private func refreshFiles() {
        supportsFileTransfer = selectedImage.map(workspace.floppySupportsFileTransfer(at:)) ?? false
        files = supportsFileTransfer ? (selectedImage.map(workspace.floppyFiles(at:)) ?? []) : []
        selectedFile = nil
    }
    private func importImage() {
        let panel = NSOpenPanel(); panel.title = "Import Floppy Image"; panel.prompt = "Import"; panel.allowsMultipleSelection = false
        guard panel.runModal() == .OK, let url = panel.url else { return }
        if workspace.importFloppyToStore(from: url) { refresh() }
    }
    private func addFiles(to image: URL) {
        let panel = NSOpenPanel(); panel.title = "Add Files to \(image.lastPathComponent)"; panel.prompt = "Add"; panel.allowsMultipleSelection = true
        guard panel.runModal() == .OK else { return }
        if workspace.addFiles(panel.urls, toFloppy: image) { refreshFiles() }
    }
    private func exportSelected(from image: URL) {
        guard let selectedFile else { return }
        let panel = NSSavePanel(); panel.nameFieldStringValue = selectedFile.name; panel.title = "Export \(selectedFile.name)"
        guard panel.runModal() == .OK, let url = panel.url else { return }
        _ = workspace.exportFloppyFile(selectedFile, from: image, to: url)
    }
}
#endif
