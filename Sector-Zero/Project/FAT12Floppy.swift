import Foundation

/// A deliberately small FAT12 implementation for the standard 1.44 MB DOS
/// floppy format. It is used by the media library, not by the emulator, so
/// images remain ordinary raw `.img` files that can be used elsewhere.
enum FAT12Floppy {
    static let byteCount = 1_474_560
    private static let bytesPerSector = 512
    private static let sectorsPerCluster = 1
    private static let reservedSectors = 1
    private static let fatCount = 2
    private static let sectorsPerFAT = 9
    private static let rootEntryCount = 224
    private static let rootDirectorySectors = 14
    private static let firstDataSector = 33
    private static let clusterCount = 2_847

    struct Entry: Identifiable, Equatable, Hashable {
        let name: String
        let byteCount: Int
        fileprivate let firstCluster: Int
        var id: String { name }
    }

    enum Error: LocalizedError {
        case unsupportedImage
        case invalidFileName(String)
        case fileAlreadyExists(String)
        case diskFull
        case fileNotFound

        var errorDescription: String? {
            switch self {
            case .unsupportedImage: "This floppy is not a standard FAT12 1.44 MB disk."
            case .invalidFileName(let name): "\(name) cannot be stored as a DOS 8.3 file name."
            case .fileAlreadyExists(let name): "\(name) is already on this floppy."
            case .diskFull: "There is not enough free space on this floppy."
            case .fileNotFound: "That file is no longer on this floppy."
            }
        }
    }

    static func blankImage() -> Data {
        var bytes = [UInt8](repeating: 0, count: byteCount)
        bytes[0] = 0xEB; bytes[1] = 0x3C; bytes[2] = 0x90
        Array("MSDOS5.0".utf8).enumerated().forEach { bytes[3 + $0.offset] = $0.element }
        write16(&bytes, 11, bytesPerSector); bytes[13] = UInt8(sectorsPerCluster)
        write16(&bytes, 14, reservedSectors); bytes[16] = UInt8(fatCount)
        write16(&bytes, 17, rootEntryCount); write16(&bytes, 19, 2_880)
        bytes[21] = 0xF0; write16(&bytes, 22, sectorsPerFAT)
        write16(&bytes, 24, 18); write16(&bytes, 26, 2)
        write32(&bytes, 28, 0); write32(&bytes, 32, 0)
        bytes[36] = 0; bytes[38] = 0x29
        write32(&bytes, 39, UInt32.random(in: 1...UInt32.max))
        Array("SECTOR ZERO".utf8).enumerated().forEach { bytes[43 + $0.offset] = $0.element }
        Array("FAT12   ".utf8).enumerated().forEach { bytes[54 + $0.offset] = $0.element }
        bytes[510] = 0x55; bytes[511] = 0xAA
        for fat in 0..<fatCount {
            let offset = (reservedSectors + fat * sectorsPerFAT) * bytesPerSector
            bytes[offset] = 0xF0; bytes[offset + 1] = 0xFF; bytes[offset + 2] = 0xFF
        }
        return Data(bytes)
    }

    static func entries(in image: Data) throws -> [Entry] {
        let bytes = try validated(image)
        return rootEntries(bytes).compactMap { record in
            guard record[0] != 0, record[0] != 0xE5, record[11] & 0x0F != 0x0F, record[11] & 0x08 == 0 else { return nil }
            let base = String(bytes: record[0..<8], encoding: .ascii)!.trimmingCharacters(in: .whitespaces)
            let ext = String(bytes: record[8..<11], encoding: .ascii)!.trimmingCharacters(in: .whitespaces)
            let name = ext.isEmpty ? base : "\(base).\(ext)"
            return Entry(name: name, byteCount: Int(read32(record, 28)), firstCluster: Int(read16(record, 26)))
        }
    }

    static func supportsFileTransfer(_ image: Data) -> Bool {
        (try? validated(image)) != nil
    }

    static func adding(files: [URL], to image: Data) throws -> Data {
        var bytes = Array(try validated(image))
        var knownNames = Set(try entries(in: Data(bytes)).map { $0.name.uppercased() })
        for file in files {
            let name = try dosName(file.lastPathComponent)
            let displayName = printableName(name)
            guard !knownNames.contains(displayName.uppercased()) else { throw Error.fileAlreadyExists(displayName) }
            let contents = try Data(contentsOf: file)
            let requiredClusters = max(1, (contents.count + bytesPerSector - 1) / bytesPerSector)
            let clusters = try freeClusters(in: bytes, count: requiredClusters)
            guard let directoryOffset = freeDirectoryOffset(in: bytes) else { throw Error.diskFull }
            for (index, cluster) in clusters.enumerated() {
                let next = index + 1 < clusters.count ? clusters[index + 1] : 0xFFF
                setFAT(&bytes, cluster: cluster, value: next)
                let dataOffset = (firstDataSector + (cluster - 2)) * bytesPerSector
                let start = index * bytesPerSector
                let end = min(start + bytesPerSector, contents.count)
                if start < end { bytes.replaceSubrange(dataOffset..<(dataOffset + end - start), with: contents[start..<end]) }
            }
            for i in 0..<11 { bytes[directoryOffset + i] = name[i] }
            bytes[directoryOffset + 11] = 0x20
            write16(&bytes, directoryOffset + 26, clusters[0])
            write32(&bytes, directoryOffset + 28, UInt32(contents.count))
            knownNames.insert(displayName.uppercased())
        }
        return Data(bytes)
    }

    static func contents(of entry: Entry, in image: Data) throws -> Data {
        let bytes = Array(try validated(image))
        guard try entries(in: Data(bytes)).contains(entry) else { throw Error.fileNotFound }
        var output = [UInt8](); var cluster = entry.firstCluster; var remaining = entry.byteCount
        while remaining > 0, cluster >= 2, cluster < 0xFF8 {
            let offset = (firstDataSector + cluster - 2) * bytesPerSector
            let count = min(bytesPerSector, remaining)
            output += bytes[offset..<(offset + count)]
            remaining -= count; cluster = fatValue(bytes, cluster: cluster)
        }
        return Data(output)
    }

    private static func validated(_ image: Data) throws -> [UInt8] {
        let bytes = Array(image)
        guard bytes.count == byteCount, read16(bytes, 11) == bytesPerSector, bytes[16] == fatCount, bytes[21] == 0xF0, read16(bytes, 22) == sectorsPerFAT else { throw Error.unsupportedImage }
        return bytes
    }
    private static func rootEntries(_ bytes: [UInt8]) -> [[UInt8]] {
        let start = (reservedSectors + fatCount * sectorsPerFAT) * bytesPerSector
        return stride(from: start, to: start + rootDirectorySectors * bytesPerSector, by: 32).map { Array(bytes[$0..<($0 + 32)]) }
    }
    private static func freeDirectoryOffset(in bytes: [UInt8]) -> Int? {
        let start = (reservedSectors + fatCount * sectorsPerFAT) * bytesPerSector
        return stride(from: start, to: start + rootDirectorySectors * bytesPerSector, by: 32).first { bytes[$0] == 0 || bytes[$0] == 0xE5 }
    }
    private static func freeClusters(in bytes: [UInt8], count: Int) throws -> [Int] {
        let clusters = (2..<(clusterCount + 2)).filter { fatValue(bytes, cluster: $0) == 0 }
        guard clusters.count >= count else { throw Error.diskFull }; return Array(clusters.prefix(count))
    }
    private static func fatValue(_ bytes: [UInt8], cluster: Int) -> Int {
        let offset = reservedSectors * bytesPerSector + cluster + cluster / 2
        let value = Int(bytes[offset]) | Int(bytes[offset + 1]) << 8
        return cluster.isMultiple(of: 2) ? value & 0xFFF : value >> 4
    }
    private static func setFAT(_ bytes: inout [UInt8], cluster: Int, value: Int) {
        for fat in 0..<fatCount {
            let offset = (reservedSectors + fat * sectorsPerFAT) * bytesPerSector + cluster + cluster / 2
            if cluster.isMultiple(of: 2) { bytes[offset] = UInt8(value & 0xFF); bytes[offset + 1] = (bytes[offset + 1] & 0xF0) | UInt8((value >> 8) & 0x0F) }
            else { bytes[offset] = (bytes[offset] & 0x0F) | UInt8((value << 4) & 0xF0); bytes[offset + 1] = UInt8((value >> 4) & 0xFF) }
        }
    }
    private static func dosName(_ raw: String) throws -> [UInt8] {
        let parts = raw.uppercased().split(separator: ".", maxSplits: 1, omittingEmptySubsequences: false)
        guard let base = parts.first, !base.isEmpty, base.count <= 8, parts.count <= 2, (parts.count == 1 || parts[1].count <= 3), base.allSatisfy(isDOSCharacter), (parts.count == 1 || parts[1].allSatisfy(isDOSCharacter)) else { throw Error.invalidFileName(raw) }
        return Array((String(base).padding(toLength: 8, withPad: " ", startingAt: 0) + (parts.count == 2 ? String(parts[1]) : "").padding(toLength: 3, withPad: " ", startingAt: 0)).utf8)
    }
    nonisolated private static func isDOSCharacter(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || "!#$%&'()-@^_`{}~".contains(c)) }
    private static func printableName(_ bytes: [UInt8]) -> String { let b = String(bytes: bytes[0..<8], encoding: .ascii)!.trimmingCharacters(in: .whitespaces); let e = String(bytes: bytes[8..<11], encoding: .ascii)!.trimmingCharacters(in: .whitespaces); return e.isEmpty ? b : "\(b).\(e)" }
    private static func read16(_ bytes: [UInt8], _ offset: Int) -> Int { Int(bytes[offset]) | Int(bytes[offset + 1]) << 8 }
    private static func read32(_ bytes: [UInt8], _ offset: Int) -> UInt32 { UInt32(bytes[offset]) | UInt32(bytes[offset + 1]) << 8 | UInt32(bytes[offset + 2]) << 16 | UInt32(bytes[offset + 3]) << 24 }
    private static func write16(_ bytes: inout [UInt8], _ offset: Int, _ value: Int) { bytes[offset] = UInt8(value & 0xFF); bytes[offset + 1] = UInt8((value >> 8) & 0xFF) }
    private static func write32(_ bytes: inout [UInt8], _ offset: Int, _ value: UInt32) { for i in 0..<4 { bytes[offset + i] = UInt8((value >> UInt32(i * 8)) & 0xFF) } }
}
