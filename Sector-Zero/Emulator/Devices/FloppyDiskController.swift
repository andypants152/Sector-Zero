import Foundation

struct FloppyDiskGeometry: Equatable, Sendable {
    let tracks: Int
    let heads: Int
    let sectorsPerTrack: Int
    let bytesPerSector: Int

    var byteCount: Int {
        tracks * heads * sectorsPerTrack * bytesPerSector
    }

    static func detect(byteCount: Int) throws -> FloppyDiskGeometry {
        guard let geometry = supported.first(where: { $0.byteCount == byteCount }) else {
            throw FloppyDiskImageError.unsupportedSize(byteCount)
        }
        return geometry
    }

    static let supported: [FloppyDiskGeometry] = [
        FloppyDiskGeometry(tracks: 40, heads: 1, sectorsPerTrack: 8, bytesPerSector: 512),
        FloppyDiskGeometry(tracks: 40, heads: 1, sectorsPerTrack: 9, bytesPerSector: 512),
        FloppyDiskGeometry(tracks: 40, heads: 2, sectorsPerTrack: 8, bytesPerSector: 512),
        FloppyDiskGeometry(tracks: 40, heads: 2, sectorsPerTrack: 9, bytesPerSector: 512),
        FloppyDiskGeometry(tracks: 80, heads: 2, sectorsPerTrack: 9, bytesPerSector: 512),
        FloppyDiskGeometry(tracks: 80, heads: 2, sectorsPerTrack: 15, bytesPerSector: 512),
        FloppyDiskGeometry(tracks: 80, heads: 2, sectorsPerTrack: 18, bytesPerSector: 512),
    ]
}

enum FloppyDiskImageError: Error, Equatable, Sendable {
    case unsupportedSize(Int)
}

extension FloppyDiskImageError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .unsupportedSize(let size):
            return "Unsupported floppy image size: \(size) bytes."
        }
    }
}

enum FloppyControllerPhase: Equatable, Sendable {
    case idle
    case command
    case execution
    case result
}

struct FloppyDiskControllerSnapshot: Equatable, Sendable {
    let phase: FloppyControllerPhase
    let digitalOutput: UInt8
    let mainStatus: UInt8
    let selectedDrive: UInt8
    let currentCylinder: UInt8
    let commandByteCount: Int
    let resultByteCount: Int
    let pendingInterruptCount: Int
    let dmaRequestActive: Bool
    let mediaGeometry: FloppyDiskGeometry?
    let mediaByteCount: Int
    let drives: [FloppyDriveSnapshot]
    let writeCount: Int
    let persistenceError: String?
    let recentReads: [FloppyReadTrace]
    let recentWrites: [FloppyWriteTrace]
}

struct FloppyDriveSnapshot: Equatable, Sendable {
    let geometry: FloppyDiskGeometry?
    let mediaByteCount: Int
}

struct FloppyReadTrace: Equatable, Sendable {
    var drive: UInt8 = 0
    let cylinder: UInt8
    let head: UInt8
    let sector: UInt8
    let endOfTrack: UInt8
    let dmaAddress: UInt32
    let byteCount: Int
}

struct FloppyWriteTrace: Equatable, Sendable {
    let drive: UInt8
    let cylinder: UInt8
    let head: UInt8
    let sector: UInt8
    let byteCount: Int
}

/// Intel 8272/NEC 765 subset behind the original PC floppy ports. The first
/// milestone implements command/result framing, reset, seek/recalibrate,
/// sense and READ ID commands, and DMA-backed READ/WRITE DATA for drives 0 and
/// 1. The broader diagnostic/format command set remains deliberately small.
final class FloppyDiskController: IOPortDevice {
    static let digitalOutputPort: UInt16 = 0x3F2
    static let mainStatusPort: UInt16 = 0x3F4
    static let dataPort: UInt16 = 0x3F5
    static let digitalInputPort: UInt16 = 0x3F7
    static let portRange: ClosedRange<UInt16> = 0x3F2...0x3F7

    private struct Media {
        var bytes: [UInt8]
        let geometry: FloppyDiskGeometry
        let fileURL: URL?
        var persistenceError: String?

        func sector(cylinder: Int, head: Int, sector: Int) -> ArraySlice<UInt8> {
            let logicalSector = (cylinder * geometry.heads + head) * geometry.sectorsPerTrack
                + (sector - 1)
            let start = logicalSector * geometry.bytesPerSector
            return bytes[start..<(start + geometry.bytesPerSector)]
        }

        mutating func writeSector(_ source: ArraySlice<UInt8>, cylinder: Int, head: Int, sector: Int) {
            let logicalSector = (cylinder * geometry.heads + head) * geometry.sectorsPerTrack
                + (sector - 1)
            let start = logicalSector * geometry.bytesPerSector
            bytes.replaceSubrange(start..<(start + source.count), with: source)
            guard let fileURL else { return }
            do {
                let handle = try FileHandle(forUpdating: fileURL)
                defer { try? handle.close() }
                try handle.seek(toOffset: UInt64(start))
                try handle.write(contentsOf: Data(source))
            } catch {
                persistenceError = error.localizedDescription
            }
        }
    }

    private struct SectorID {
        let cylinder: UInt8
        let head: UInt8
        let sector: UInt8
        let sizeCode: UInt8
    }

    private struct ReadExecution {
        let drive: UInt8
        let bytes: [UInt8]
        let sectors: [SectorID]
        let bytesPerSector: Int
        var byteIndex = 0

        var currentSector: SectorID {
            let lastTransferredByte = max(byteIndex - 1, 0)
            let sectorIndex = min(lastTransferredByte / bytesPerSector, sectors.count - 1)
            return sectors[sectorIndex]
        }
    }

    private struct WriteExecution {
        let drive: UInt8
        let sectors: [SectorID]
        let bytesPerSector: Int
        var bytes: [UInt8] = []

        var currentSector: SectorID {
            let sectorIndex = min(max(bytes.count - 1, 0) / bytesPerSector, sectors.count - 1)
            return sectors[sectorIndex]
        }
    }

    private let interruptController: ProgrammableInterruptController
    private let dmaController: DirectMemoryAccessController
    private var media = Array<Media?>(repeating: nil, count: 4)
    private var digitalOutput: UInt8 = 0
    private var commandBytes: [UInt8] = []
    private var expectedCommandByteCount = 0
    private var resultBytes: [UInt8] = []
    private var readExecution: ReadExecution?
    private var writeExecution: WriteExecution?
    private var pendingInterrupts: [(status: UInt8, cylinder: UInt8)] = []
    private var cylinders = Array(repeating: UInt8(0), count: 4)
    private var specifyBytes: (UInt8, UInt8) = (0, 0)
    private var recentReads: [FloppyReadTrace] = []
    private var recentWrites: [FloppyWriteTrace] = []
    private var writeCount = 0
    private static let maximumRecordedReads = 128

    init(
        interruptController: ProgrammableInterruptController,
        dmaController: DirectMemoryAccessController
    ) {
        self.interruptController = interruptController
        self.dmaController = dmaController
    }

    var phase: FloppyControllerPhase {
        if readExecution != nil || writeExecution != nil { return .execution }
        if !resultBytes.isEmpty { return .result }
        if !commandBytes.isEmpty { return .command }
        return .idle
    }

    var mainStatus: UInt8 {
        let driveBusy = phase == .idle ? UInt8(0) : UInt8(1 << selectedDrive)
        switch phase {
        case .idle: return 0x80
        case .command: return 0x90 | driveBusy
        case .execution: return 0x10 | driveBusy
        case .result: return 0xD0 | driveBusy
        }
    }

    var selectedDrive: UInt8 { digitalOutput & 0x03 }
    var controllerEnabled: Bool { digitalOutput & 0x04 != 0 }
    var dmaAndInterruptEnabled: Bool { digitalOutput & 0x08 != 0 }

    var dmaRequestActive: Bool {
        (readExecution != nil || writeExecution != nil) && controllerEnabled && dmaAndInterruptEnabled
    }

    var snapshot: FloppyDiskControllerSnapshot {
        FloppyDiskControllerSnapshot(
            phase: phase,
            digitalOutput: digitalOutput,
            mainStatus: mainStatus,
            selectedDrive: selectedDrive,
            currentCylinder: cylinders[Int(selectedDrive)],
            commandByteCount: commandBytes.count,
            resultByteCount: resultBytes.count,
            pendingInterruptCount: pendingInterrupts.count,
            dmaRequestActive: dmaRequestActive,
            mediaGeometry: media[0]?.geometry,
            mediaByteCount: media[0]?.bytes.count ?? 0,
            drives: media.map { FloppyDriveSnapshot(
                geometry: $0?.geometry,
                mediaByteCount: $0?.bytes.count ?? 0
            ) },
            writeCount: writeCount,
            persistenceError: media.compactMap { $0?.persistenceError }.first,
            recentReads: recentReads,
            recentWrites: recentWrites
        )
    }

    func mount(_ image: Data, drive: UInt8 = 0, fileURL: URL? = nil) throws {
        guard drive < 4 else { throw FloppyDiskImageError.unsupportedSize(image.count) }
        let geometry = try FloppyDiskGeometry.detect(byteCount: image.count)
        media[Int(drive)] = Media(bytes: Array(image), geometry: geometry, fileURL: fileURL)
    }

    func eject(drive: UInt8 = 0) {
        guard drive < 4 else { return }
        media[Int(drive)] = nil
        if readExecution?.drive == drive || writeExecution?.drive == drive {
            finishTransferFailure(status0: 0x48 | drive, status1: 0x04)
        }
    }

    /// Resets controller electronics while preserving host-mounted media.
    func reset() {
        digitalOutput = 0
        resetControllerState()
        pendingInterrupts.removeAll()
        cylinders = Array(repeating: 0, count: 4)
        specifyBytes = (0, 0)
        recentReads.removeAll(keepingCapacity: true)
        recentWrites.removeAll(keepingCapacity: true)
        writeCount = 0
    }

    func readByte(from port: UInt16) -> UInt8 {
        switch port {
        case Self.digitalOutputPort:
            return digitalOutput
        case Self.mainStatusPort:
            return mainStatus
        case Self.dataPort:
            return readDataRegister()
        case Self.digitalInputPort:
            return media[Int(selectedDrive)] == nil ? 0x80 : 0x00
        default:
            return 0xFF
        }
    }

    func writeByte(_ value: UInt8, to port: UInt16) {
        switch port {
        case Self.digitalOutputPort:
            writeDigitalOutput(value)
        case Self.dataPort:
            writeDataRegister(value)
        default:
            break
        }
    }

    func takeDMAByte() -> UInt8 {
        guard var execution = readExecution,
              execution.byteIndex < execution.bytes.count else {
            return 0xFF
        }
        let byte = execution.bytes[execution.byteIndex]
        execution.byteIndex += 1
        readExecution = execution
        return byte
    }

    func putDMAByte(_ byte: UInt8) {
        guard var execution = writeExecution,
              execution.bytes.count < execution.sectors.count * execution.bytesPerSector else {
            return
        }
        execution.bytes.append(byte)
        writeExecution = execution
    }

    func completeDMAService(_ result: DMAServiceResult) {
        guard result.transferred else { return }
        if let execution = readExecution,
           result.reachedTerminalCount || execution.byteIndex >= execution.bytes.count {
            finishTransferSuccess(execution.currentSector, drive: execution.drive)
        } else if let execution = writeExecution,
                  result.reachedTerminalCount || execution.bytes.count >= execution.sectors.count * execution.bytesPerSector {
            finishWriteSuccess(execution)
        }
    }

    private func writeDigitalOutput(_ value: UInt8) {
        let wasEnabled = controllerEnabled
        digitalOutput = value
        let isEnabled = controllerEnabled

        if !isEnabled {
            resetControllerState()
            return
        }
        if !wasEnabled {
            resetControllerState()
            cylinders = Array(repeating: 0, count: 4)
            pendingInterrupts = (0..<4).map { (0xC0 | UInt8($0), 0) }
            assertInterrupt()
        } else if !dmaAndInterruptEnabled {
            interruptController.lower(.floppy)
        }
        syncDMARequest()
    }

    private func writeDataRegister(_ value: UInt8) {
        guard controllerEnabled, phase != .execution, phase != .result else { return }

        if commandBytes.isEmpty {
            commandBytes = [value]
            expectedCommandByteCount = commandLength(for: value)
        } else {
            commandBytes.append(value)
        }

        if commandBytes.count == expectedCommandByteCount {
            let completeCommand = commandBytes
            commandBytes.removeAll(keepingCapacity: true)
            expectedCommandByteCount = 0
            execute(completeCommand)
        }
    }

    private func readDataRegister() -> UInt8 {
        guard !resultBytes.isEmpty else { return 0xFF }
        interruptController.lower(.floppy)
        let byte = resultBytes.removeFirst()
        return byte
    }

    private func commandLength(for command: UInt8) -> Int {
        switch command & 0x1F {
        case 0x03: return 3  // SPECIFY
        case 0x04: return 2  // SENSE DRIVE STATUS
        case 0x05: return 9  // WRITE DATA
        case 0x06: return 9  // READ DATA
        case 0x07: return 2  // RECALIBRATE
        case 0x08: return 1  // SENSE INTERRUPT STATUS
        case 0x0A: return 2  // READ ID
        case 0x0F: return 3  // SEEK
        default: return 1
        }
    }

    private func execute(_ command: [UInt8]) {
        switch command[0] & 0x1F {
        case 0x03:
            specifyBytes = (command[1], command[2])
        case 0x04:
            senseDriveStatus(command)
        case 0x05:
            beginWriteData(command)
        case 0x06:
            beginReadData(command)
        case 0x07:
            recalibrate(command)
        case 0x08:
            senseInterruptStatus()
        case 0x0A:
            readID(command)
        case 0x0F:
            seek(command)
        default:
            enterResult([0x80], raisesInterrupt: false)
        }
    }

    private func senseDriveStatus(_ command: [UInt8]) {
        let driveAndHead = command[1]
        let drive = driveAndHead & 0x03
        let head = driveAndHead >> 2 & 0x01
        var status3 = drive | head << 2
        if cylinders[Int(drive)] == 0 { status3 |= 0x10 }
        if media[Int(drive)] != nil { status3 |= 0x20 }
        if media[Int(drive)]?.geometry.heads == 2 { status3 |= 0x08 }
        enterResult([status3], raisesInterrupt: false)
    }

    private func recalibrate(_ command: [UInt8]) {
        let drive = command[1] & 0x03
        cylinders[Int(drive)] = 0
        pendingInterrupts.append((0x20 | drive, 0))
        assertInterrupt()
    }

    private func seek(_ command: [UInt8]) {
        let driveAndHead = command[1]
        let drive = driveAndHead & 0x03
        let head = driveAndHead >> 2 & 0x01
        let cylinder = command[2]
        cylinders[Int(drive)] = cylinder
        pendingInterrupts.append((0x20 | head << 2 | drive, cylinder))
        assertInterrupt()
    }

    private func senseInterruptStatus() {
        interruptController.lower(.floppy)
        guard !pendingInterrupts.isEmpty else {
            enterResult([0x80], raisesInterrupt: false)
            return
        }
        let pending = pendingInterrupts.removeFirst()
        enterResult([pending.status, pending.cylinder], raisesInterrupt: false)
    }

    private func readID(_ command: [UInt8]) {
        let driveAndHead = command[1]
        let drive = driveAndHead & 0x03
        let head = driveAndHead >> 2 & 0x01
        let cylinder = cylinders[Int(drive)]
        guard let mountedMedia = media[Int(drive)] else {
            enterResult([0x48 | head << 2 | drive, 0x04, 0, cylinder, head, 1, 2], raisesInterrupt: true)
            return
        }
        guard Int(cylinder) < mountedMedia.geometry.tracks,
              Int(head) < mountedMedia.geometry.heads else {
            enterResult([
                0x40 | head << 2 | drive,
                0x04,
                Int(cylinder) >= mountedMedia.geometry.tracks ? 0x10 : 0,
                cylinder,
                head,
                1,
                2,
            ], raisesInterrupt: true)
            return
        }
        // Rotation is intentionally deterministic: expose the final sector ID
        // on the track so firmware can qualify media without a private register.
        enterResult([
            head << 2 | drive,
            0,
            0,
            cylinder,
            head,
            UInt8(mountedMedia.geometry.sectorsPerTrack),
            2,
        ], raisesInterrupt: true)
    }

    private func beginReadData(_ command: [UInt8]) {
        let driveAndHead = command[1]
        let drive = driveAndHead & 0x03
        let selectedHead = driveAndHead >> 2 & 0x01
        let cylinder = command[2]
        let head = command[3]
        let sector = command[4]
        let sizeCode = command[5]
        let endOfTrack = command[6]

        guard let mountedMedia = media[Int(drive)] else {
            finishTransferFailure(
                status0: 0x48 | selectedHead << 2 | drive,
                status1: 0x04,
                cylinder: cylinder,
                head: head,
                sector: sector,
                sizeCode: sizeCode
            )
            return
        }
        guard sizeCode == 2,
              Int(cylinder) < mountedMedia.geometry.tracks,
              head == selectedHead,
              Int(head) < mountedMedia.geometry.heads,
              sector > 0,
              sector <= endOfTrack,
              Int(endOfTrack) <= mountedMedia.geometry.sectorsPerTrack else {
            let endOfCylinder = Int(endOfTrack) > mountedMedia.geometry.sectorsPerTrack ? UInt8(0x80) : 0
            finishTransferFailure(
                status0: 0x40 | selectedHead << 2 | drive,
                status1: 0x04 | endOfCylinder,
                status2: Int(cylinder) >= mountedMedia.geometry.tracks ? 0x10 : 0,
                cylinder: cylinder,
                head: head,
                sector: sector,
                sizeCode: sizeCode
            )
            return
        }

        var sectorIDs: [SectorID] = []
        for currentSector in sector...endOfTrack {
            sectorIDs.append(SectorID(
                cylinder: cylinder,
                head: head,
                sector: currentSector,
                sizeCode: sizeCode
            ))
        }
        if command[0] & 0x80 != 0, head == 0, mountedMedia.geometry.heads > 1 {
            for currentSector in UInt8(1)...endOfTrack {
                sectorIDs.append(SectorID(
                    cylinder: cylinder,
                    head: 1,
                    sector: currentSector,
                    sizeCode: sizeCode
                ))
            }
        }

        var transferBytes: [UInt8] = []
        transferBytes.reserveCapacity(sectorIDs.count * mountedMedia.geometry.bytesPerSector)
        for id in sectorIDs {
            transferBytes.append(contentsOf: mountedMedia.sector(
                cylinder: Int(id.cylinder),
                head: Int(id.head),
                sector: Int(id.sector)
            ))
        }
        let dma = dmaController.snapshot.channel2
        if recentReads.count == Self.maximumRecordedReads {
            recentReads.removeFirst()
        }
        recentReads.append(FloppyReadTrace(
            drive: drive,
            cylinder: cylinder,
            head: head,
            sector: sector,
            endOfTrack: endOfTrack,
            dmaAddress: dma.physicalAddress,
            byteCount: Int(dma.currentCount) + 1
        ))
        readExecution = ReadExecution(
            drive: drive,
            bytes: transferBytes,
            sectors: sectorIDs,
            bytesPerSector: mountedMedia.geometry.bytesPerSector
        )
        syncDMARequest()
    }

    private func beginWriteData(_ command: [UInt8]) {
        let driveAndHead = command[1]
        let drive = driveAndHead & 0x03
        let selectedHead = driveAndHead >> 2 & 0x01
        let cylinder = command[2]
        let head = command[3]
        let sector = command[4]
        let sizeCode = command[5]
        let endOfTrack = command[6]

        guard let mountedMedia = media[Int(drive)] else {
            finishTransferFailure(
                status0: 0x48 | selectedHead << 2 | drive,
                status1: 0x04,
                cylinder: cylinder,
                head: head,
                sector: sector,
                sizeCode: sizeCode
            )
            return
        }
        guard sizeCode == 2,
              Int(cylinder) < mountedMedia.geometry.tracks,
              head == selectedHead,
              Int(head) < mountedMedia.geometry.heads,
              sector > 0,
              sector <= endOfTrack,
              Int(endOfTrack) <= mountedMedia.geometry.sectorsPerTrack else {
            finishTransferFailure(
                status0: 0x40 | selectedHead << 2 | drive,
                status1: 0x04 | (Int(endOfTrack) > mountedMedia.geometry.sectorsPerTrack ? 0x80 : 0),
                status2: Int(cylinder) >= mountedMedia.geometry.tracks ? 0x10 : 0,
                cylinder: cylinder,
                head: head,
                sector: sector,
                sizeCode: sizeCode
            )
            return
        }

        var sectors = (sector...endOfTrack).map {
            SectorID(cylinder: cylinder, head: head, sector: $0, sizeCode: sizeCode)
        }
        if command[0] & 0x80 != 0, head == 0, mountedMedia.geometry.heads > 1 {
            sectors += (UInt8(1)...endOfTrack).map {
                SectorID(cylinder: cylinder, head: 1, sector: $0, sizeCode: sizeCode)
            }
        }
        writeExecution = WriteExecution(
            drive: drive,
            sectors: sectors,
            bytesPerSector: mountedMedia.geometry.bytesPerSector
        )
        syncDMARequest()
    }

    private func finishTransferSuccess(_ sector: SectorID, drive: UInt8) {
        readExecution = nil
        writeExecution = nil
        syncDMARequest()
        enterResult([
            sector.head << 2 | drive,
            0,
            0,
            sector.cylinder,
            sector.head,
            sector.sector,
            sector.sizeCode,
        ], raisesInterrupt: true)
    }

    private func finishWriteSuccess(_ execution: WriteExecution) {
        guard var mountedMedia = media[Int(execution.drive)] else {
            finishTransferFailure(status0: 0x48 | execution.drive, status1: 0x04)
            return
        }
        for (index, id) in execution.sectors.enumerated() {
            let start = index * execution.bytesPerSector
            let end = start + execution.bytesPerSector
            guard end <= execution.bytes.count else {
                finishTransferFailure(
                    status0: 0x40 | id.head << 2 | execution.drive,
                    status1: 0x10,
                    cylinder: id.cylinder,
                    head: id.head,
                    sector: id.sector,
                    sizeCode: id.sizeCode
                )
                return
            }
            mountedMedia.writeSector(
                execution.bytes[start..<end],
                cylinder: Int(id.cylinder),
                head: Int(id.head),
                sector: Int(id.sector)
            )
        }
        media[Int(execution.drive)] = mountedMedia
        writeCount += execution.sectors.count
        if recentWrites.count == Self.maximumRecordedReads { recentWrites.removeFirst() }
        let first = execution.sectors[0]
        recentWrites.append(FloppyWriteTrace(
            drive: execution.drive,
            cylinder: first.cylinder,
            head: first.head,
            sector: first.sector,
            byteCount: execution.bytes.count
        ))
        finishTransferSuccess(execution.currentSector, drive: execution.drive)
    }

    private func finishTransferFailure(
        status0: UInt8,
        status1: UInt8,
        status2: UInt8 = 0,
        cylinder: UInt8 = 0,
        head: UInt8 = 0,
        sector: UInt8 = 1,
        sizeCode: UInt8 = 2
    ) {
        readExecution = nil
        writeExecution = nil
        syncDMARequest()
        enterResult([
            status0, status1, status2, cylinder, head, sector, sizeCode,
        ], raisesInterrupt: true)
    }

    private func enterResult(_ bytes: [UInt8], raisesInterrupt: Bool) {
        resultBytes = bytes
        if raisesInterrupt { assertInterrupt() }
    }

    private func assertInterrupt() {
        guard dmaAndInterruptEnabled else { return }
        interruptController.raise(.floppy)
    }

    private func syncDMARequest() {
        dmaController.setChannel2HardwareRequest(dmaRequestActive)
    }

    private func resetControllerState() {
        commandBytes.removeAll(keepingCapacity: true)
        expectedCommandByteCount = 0
        resultBytes.removeAll(keepingCapacity: true)
        readExecution = nil
        writeExecution = nil
        pendingInterrupts.removeAll(keepingCapacity: true)
        interruptController.lower(.floppy)
        syncDMARequest()
    }
}
