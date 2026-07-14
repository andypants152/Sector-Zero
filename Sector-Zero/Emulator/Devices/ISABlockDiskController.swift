import Foundation

struct FixedDiskGeometry: Equatable, Sendable {
    let cylinders: Int
    let heads: Int
    let sectorsPerTrack: Int
    let bytesPerSector: Int

    var sectorCount: Int { cylinders * heads * sectorsPerTrack }
    var byteCount: Int { sectorCount * bytesPerSector }

    /// A common early-XT geometry: roughly 20 MB and safely below the DOS 2.x
    /// 32 MB partition ceiling.
    static let classic20MB = FixedDiskGeometry(
        cylinders: 615,
        heads: 4,
        sectorsPerTrack: 17,
        bytesPerSector: 512
    )

    static func detect(byteCount: Int) throws -> FixedDiskGeometry {
        guard byteCount > 0, byteCount % 512 == 0 else {
            throw FixedDiskImageError.unsupportedSize(byteCount)
        }
        let sectors = byteCount / 512
        // Prefer period-appropriate 17-sector geometries, then accept common
        // translated raw images when their size maps exactly to CHS.
        for (heads, sectorsPerTrack) in [(4, 17), (8, 17), (16, 17), (16, 63)] {
            let sectorsPerCylinder = heads * sectorsPerTrack
            guard sectors % sectorsPerCylinder == 0 else { continue }
            let cylinders = sectors / sectorsPerCylinder
            guard (1...1_024).contains(cylinders) else { continue }
            return FixedDiskGeometry(
                cylinders: cylinders,
                heads: heads,
                sectorsPerTrack: sectorsPerTrack,
                bytesPerSector: 512
            )
        }
        throw FixedDiskImageError.unsupportedSize(byteCount)
    }
}

enum FixedDiskImageError: Error, Equatable, Sendable {
    case unsupportedSize(Int)
}

extension FixedDiskImageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedSize(let size):
            "Unsupported hard-disk image size: \(size) bytes. Use an exact CHS raw image."
        }
    }
}

enum ISABlockTransferDirection: Equatable, Sendable {
    case read
    case write
}

struct ISABlockTransferTrace: Equatable, Sendable {
    let direction: ISABlockTransferDirection
    let cylinder: UInt16
    let head: UInt8
    let sector: UInt8
    let sectorCount: UInt8
    let memoryAddress: UInt32
}

struct ISABlockDiskControllerSnapshot: Equatable, Sendable {
    let status: UInt8
    let mediaGeometry: FixedDiskGeometry?
    let mediaByteCount: Int
    let writeCount: Int
    let persistenceError: String?
    let recentTransfers: [ISABlockTransferTrace]
}

/// A clean-room, PicoMEM-inspired ISA block adapter. It is intentionally a
/// command device rather than a fictional MFM mechanism: the BIOS supplies
/// CHS plus a conventional-memory window, and the adapter copies sectors to or
/// from its mounted raw image. This mirrors PicoMEM's documented "disk BIOS"
/// architecture without copying its GPL implementation or private protocol.
final class ISABlockDiskController: IOPortDevice {
    static let basePort: UInt16 = 0x2A0
    static let portRange: ClosedRange<UInt16> = basePort...(basePort + 9)

    static let commandRead: UInt8 = 0x20
    static let commandWrite: UInt8 = 0x30
    static let commandIdentify: UInt8 = 0xEC
    static let commandReset: UInt8 = 0x00

    static let statusReady: UInt8 = 0x40
    static let statusInvalidCommand: UInt8 = 0x01
    static let statusSectorNotFound: UInt8 = 0x04
    static let statusDMABoundary: UInt8 = 0x09
    static let statusNotReady: UInt8 = 0x80

    private struct Media {
        var bytes: [UInt8]
        let geometry: FixedDiskGeometry
        let fileURL: URL?
        var persistenceError: String?

        mutating func write(_ source: ArraySlice<UInt8>, at offset: Int) {
            bytes.replaceSubrange(offset..<(offset + source.count), with: source)
            guard let fileURL else { return }
            do {
                let handle = try FileHandle(forUpdating: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(offset))
                try handle.write(contentsOf: Data(source))
            } catch {
                persistenceError = error.localizedDescription
            }
        }
    }

    private let memory: Memory
    private var media: Media?
    private var status = statusNotReady
    private var drive: UInt8 = 0
    private var cylinderLow: UInt8 = 0
    private var cylinderHigh: UInt8 = 0
    private var head: UInt8 = 0
    private var sector: UInt8 = 1
    private var sectorCount: UInt8 = 1
    private var memoryOffsetLow: UInt8 = 0
    private var memoryOffsetHigh: UInt8 = 0
    private var memoryPage: UInt8 = 0
    private var writeCount = 0
    private var recentTransfers: [ISABlockTransferTrace] = []
    private static let maximumRecordedTransfers = 128

    init(memory: Memory) {
        self.memory = memory
    }

    var snapshot: ISABlockDiskControllerSnapshot {
        ISABlockDiskControllerSnapshot(
            status: status,
            mediaGeometry: media?.geometry,
            mediaByteCount: media?.bytes.count ?? 0,
            writeCount: writeCount,
            persistenceError: media?.persistenceError,
            recentTransfers: recentTransfers
        )
    }

    func mount(_ image: Data, fileURL: URL? = nil) throws {
        let geometry = try FixedDiskGeometry.detect(byteCount: image.count)
        media = Media(bytes: Array(image), geometry: geometry, fileURL: fileURL)
        status = Self.statusReady
    }

    func eject() {
        media = nil
        status = Self.statusNotReady
    }

    /// Controller reset preserves mounted media, like a hardware reset.
    func reset() {
        drive = 0
        cylinderLow = 0
        cylinderHigh = 0
        head = 0
        sector = 1
        sectorCount = 1
        memoryOffsetLow = 0
        memoryOffsetHigh = 0
        memoryPage = 0
        recentTransfers.removeAll(keepingCapacity: true)
        writeCount = 0
        status = media == nil ? Self.statusNotReady : Self.statusReady
    }

    func readByte(from port: UInt16) -> UInt8 {
        switch port - Self.basePort {
        case 0: status
        case 1: drive
        case 2: cylinderLow
        case 3: cylinderHigh
        case 4: head
        case 5: sector
        case 6: sectorCount
        case 7: memoryOffsetLow
        case 8: memoryOffsetHigh
        case 9: memoryPage
        default: 0xFF
        }
    }

    func writeByte(_ value: UInt8, to port: UInt16) {
        switch port - Self.basePort {
        case 0: execute(value)
        case 1: drive = value
        case 2: cylinderLow = value
        case 3: cylinderHigh = value
        case 4: head = value
        case 5: sector = value
        case 6: sectorCount = value
        case 7: memoryOffsetLow = value
        case 8: memoryOffsetHigh = value
        case 9: memoryPage = value
        default: break
        }
    }

    private func execute(_ command: UInt8) {
        if command == Self.commandReset {
            reset()
            return
        }
        if command == Self.commandIdentify {
            guard drive == 0, let geometry = media?.geometry else {
                status = Self.statusNotReady
                return
            }
            let maximumCylinder = geometry.cylinders - 1
            cylinderLow = UInt8(truncatingIfNeeded: maximumCylinder)
            cylinderHigh = UInt8(truncatingIfNeeded: maximumCylinder >> 8)
            head = UInt8(geometry.heads - 1)
            sector = UInt8(geometry.sectorsPerTrack)
            sectorCount = 1
            status = Self.statusReady
            return
        }
        guard command == Self.commandRead || command == Self.commandWrite else {
            status = Self.statusInvalidCommand
            return
        }
        guard drive == 0, var media else {
            status = Self.statusNotReady
            return
        }
        let cylinder = UInt16(cylinderLow) | UInt16(cylinderHigh) << 8
        let count = Int(sectorCount)
        guard count > 0,
              Int(cylinder) < media.geometry.cylinders,
              Int(head) < media.geometry.heads,
              sector > 0,
              Int(sector) <= media.geometry.sectorsPerTrack else {
            status = Self.statusSectorNotFound
            return
        }

        let memoryOffset = Int(memoryOffsetLow) | Int(memoryOffsetHigh) << 8
        let byteCount = count * media.geometry.bytesPerSector
        guard memoryOffset + byteCount <= 0x1_0000 else {
            status = Self.statusDMABoundary
            return
        }
        let memoryAddress = UInt32(memoryPage & 0x0F) << 16 | UInt32(memoryOffset)
        guard memoryAddress + UInt32(byteCount) <= UInt32(Memory.addressableSize) else {
            status = Self.statusDMABoundary
            return
        }

        let firstLBA = (Int(cylinder) * media.geometry.heads + Int(head))
            * media.geometry.sectorsPerTrack + Int(sector) - 1
        guard firstLBA + count <= media.geometry.sectorCount else {
            status = Self.statusSectorNotFound
            return
        }
        let imageOffset = firstLBA * media.geometry.bytesPerSector

        if command == Self.commandRead {
            for index in 0..<byteCount {
                try? memory.writeByte(media.bytes[imageOffset + index], at: memoryAddress + UInt32(index))
            }
            record(.read, cylinder: cylinder, memoryAddress: memoryAddress)
        } else {
            var source = [UInt8]()
            source.reserveCapacity(byteCount)
            for index in 0..<byteCount {
                source.append((try? memory.readByte(at: memoryAddress + UInt32(index))) ?? 0xFF)
            }
            media.write(source[...], at: imageOffset)
            writeCount += count
            record(.write, cylinder: cylinder, memoryAddress: memoryAddress)
        }
        self.media = media
        status = Self.statusReady
    }

    private func record(
        _ direction: ISABlockTransferDirection,
        cylinder: UInt16,
        memoryAddress: UInt32
    ) {
        if recentTransfers.count == Self.maximumRecordedTransfers {
            recentTransfers.removeFirst()
        }
        recentTransfers.append(ISABlockTransferTrace(
            direction: direction,
            cylinder: cylinder,
            head: head,
            sector: sector,
            sectorCount: sectorCount,
            memoryAddress: memoryAddress
        ))
    }
}
