import Foundation
import Testing
@testable import Sector_Zero

/// Media-library FAT12 1.44 MB floppy logic.
///
/// `FAT12Floppy` is a pure, host-side image tool (it is *not* part of the
/// emulated machine), so these tests exercise its static surface directly:
/// blank-image geometry, add/read round-trips across the FAT chain, 8.3 name
/// handling, and the error paths the library UI surfaces to the user.
struct FAT12FloppyTests {
    /// A per-process scratch directory so stale files from earlier runs (a
    /// different UUID) can never collide with these tests' exact filenames.
    private static let scratch = FileManager.default.temporaryDirectory
        .appendingPathComponent("SectorZero.FAT12Tests-\(UUID().uuidString)")

    /// The specific `FAT12Floppy.Error` an add attempt produced, or `.none`.
    /// (The real `Error` carries associated values but is not `Equatable`, so we
    /// classify it here rather than compare it directly.)
    private enum Outcome {
        case none
        case invalidFileName(String)
        case fileAlreadyExists(String)
        case diskFull
    }

    private func adding(_ files: [URL], into image: Data) -> Outcome {
        do {
            _ = try FAT12Floppy.adding(files: files, to: image)
            return .none
        } catch FAT12Floppy.Error.invalidFileName(let name) {
            return .invalidFileName(name)
        } catch FAT12Floppy.Error.fileAlreadyExists(let name) {
            return .fileAlreadyExists(name)
        } catch FAT12Floppy.Error.diskFull {
            return .diskFull
        } catch {
            return .none
        }
    }

    /// Writes `contents` to a file named exactly `baseName` under the scratch
    /// directory and returns its URL. `FAT12Floppy.adding` keys off the file's
    /// `lastPathComponent`, so the on-disk name must match the name under test.
    /// The caller `removeItem`s it via `defer`.
    private func makeFile(_ baseName: String, contents: Data) throws -> URL {
        try FileManager.default.createDirectory(at: Self.scratch, withIntermediateDirectories: true)
        let url = Self.scratch.appendingPathComponent(baseName)
        try contents.write(to: url, options: .atomic)
        return url
    }

    // MARK: Blank image

    @Test("a blank image is a standard 1.44 MB FAT12 disk with the documented geometry")
    func blankImageGeometry() {
        let image = FAT12Floppy.blankImage()
        let b = [UInt8](image)

        #expect(image.count == FAT12Floppy.byteCount)
        // Boot-sector signature.
        #expect(b[510] == 0x55 && b[511] == 0xAA)
        // Fixed 1.44 MB geometry — the shape real DOS expects for drive A.
        #expect(b[11] == 0x00 && b[12] == 0x02) // 512 bytes/sector
        #expect(b[13] == 0x01)                  // 1 sector/cluster
        #expect(b[14] == 0x01 && b[15] == 0x00) // 1 reserved sector
        #expect(b[16] == 0x02)                  // 2 FATs
        #expect(b[17] == 0xE0 && b[18] == 0x00) // 224 root-directory entries (0x00E0)
        #expect(b[21] == 0xF0)                  // 1.44 MB media descriptor
        #expect(b[22] == 0x09 && b[23] == 0x00) // 9 sectors/FAT

        #expect(FAT12Floppy.supportsFileTransfer(image))
        #expect((try? FAT12Floppy.entries(in: image)) == [])
    }

    @Test("a blank image supports transfer but contains no files")
    func blankIsEmpty() throws {
        let image = FAT12Floppy.blankImage()
        #expect(try FAT12Floppy.entries(in: image).isEmpty)
    }

    // MARK: Add / read round-trips

    @Test("a single-cluster file is stored and read back intact")
    func singleClusterRoundTrip() throws {
        let contents = Data((0..<100).map { UInt8($0 % 251) })
        let file = try makeFile("HELLO.TXT", contents: contents)
        defer { try? FileManager.default.removeItem(at: file) }

        let updated = try FAT12Floppy.adding(files: [file], to: FAT12Floppy.blankImage())
        let entries = try FAT12Floppy.entries(in: updated)

        #expect(entries.count == 1)
        #expect(entries[0].name == "HELLO.TXT")
        #expect(entries[0].byteCount == contents.count)
        #expect(try FAT12Floppy.contents(of: entries[0], in: updated) == contents)
    }

    @Test("a multi-cluster file is read back in FAT-chain order")
    func multiClusterRoundTrip() throws {
        // Three 512-byte clusters (an even, then odd, then even FAT12 slot) so
        // both nibble-packing paths are exercised and any reordering is caught.
        let count = 3 * 512
        let contents = Data((0..<count).map { UInt8(($0 * 31 + 7) % 256) })
        let file = try makeFile("BIG.BIN", contents: contents)
        defer { try? FileManager.default.removeItem(at: file) }

        let updated = try FAT12Floppy.adding(files: [file], to: FAT12Floppy.blankImage())
        let entry = try FAT12Floppy.entries(in: updated)[0]

        #expect(entry.name == "BIG.BIN")
        #expect(entry.byteCount == count)
        #expect(try FAT12Floppy.contents(of: entry, in: updated) == contents)
    }

    @Test("a file whose final cluster is only partly filled round-trips")
    func partialClusterRoundTrip() throws {
        // 1000 bytes spans two clusters; the second holds 488 bytes, not 512.
        let count = 1_000
        let contents = Data((0..<count).map { UInt8(($0 * 13 + 3) % 256) })
        let file = try makeFile("PART.TXT", contents: contents)
        defer { try? FileManager.default.removeItem(at: file) }

        let updated = try FAT12Floppy.adding(files: [file], to: FAT12Floppy.blankImage())
        let entry = try FAT12Floppy.entries(in: updated)[0]

        #expect(entry.byteCount == count)
        #expect(try FAT12Floppy.contents(of: entry, in: updated) == contents)
    }

    // MARK: Name handling

    @Test("case variants of the same 8.3 name collide")
    func caseInsensitiveDuplicate() throws {
        let first = try makeFile("notes.txt", contents: Data([1, 2, 3]))
        let second = try makeFile("NOTES.TXT", contents: Data([9, 9]))
        defer {
            try? FileManager.default.removeItem(at: first)
            try? FileManager.default.removeItem(at: second)
        }

        let withFirst = try FAT12Floppy.adding(files: [first], to: FAT12Floppy.blankImage())
        let outcome = adding([second], into: withFirst)

        var collided = false
        if case .fileAlreadyExists(let name) = outcome, name.uppercased() == "NOTES.TXT" {
            collided = true
        }
        #expect(collided, "expected NOTES.TXT to be rejected as a duplicate of notes.txt")
    }

    @Test("names that are not valid DOS 8.3 are rejected")
    func invalidNames() throws {
        let offenders = [
            "TOOLONGNAME.TXT", // base exceeds 8
            "A.B.C",           // more than one dot
            "HELLO.WORLD",     // extension exceeds 3
            ".HIDDEN",         // empty base
        ]
        let image = FAT12Floppy.blankImage()

        for name in offenders {
            let file = try makeFile(name, contents: Data([0x7F]))
            var rejected = false
            if case .invalidFileName(let caught) = adding([file], into: image), caught == name {
                rejected = true
            }
            #expect(rejected, "expected \(name) to be rejected as an invalid 8.3 name")
            try FileManager.default.removeItem(at: file)
        }
    }

    // MARK: Capacity

    @Test("a file larger than the data region is rejected as a full disk")
    func diskFull() throws {
        // The largest single file that fits is 2847 * 512 bytes; one byte more
        // needs 2848 clusters but only 2847 are free. Kept at the minimum that
        // overflows so this test does not starve real-time tests of CPU/IO.
        let file = try makeFile("HUGE.BIN", contents: Data(count: 2_847 * 512 + 1))
        defer { try? FileManager.default.removeItem(at: file) }

        var reportedFull = false
        if case .diskFull = adding([file], into: FAT12Floppy.blankImage()) {
            reportedFull = true
        }
        #expect(reportedFull, "expected the over-large add to fail with diskFull")
    }

    @Test("reading a file that is not in the image fails")
    func missingFile() throws {
        let file = try makeFile("REAL.TXT", contents: Data([1, 2, 3]))
        defer { try? FileManager.default.removeItem(at: file) }

        let populated = try FAT12Floppy.adding(files: [file], to: FAT12Floppy.blankImage())
        let entry = try FAT12Floppy.entries(in: populated)[0]
        let empty = FAT12Floppy.blankImage()

        var reportedMissing = false
        do {
            _ = try FAT12Floppy.contents(of: entry, in: empty)
        } catch FAT12Floppy.Error.fileNotFound {
            reportedMissing = true
        } catch {
            Issue.record("unexpected error: \(error)")
        }
        #expect(reportedMissing, "expected fileNotFound for an entry absent from the image")
    }
}
