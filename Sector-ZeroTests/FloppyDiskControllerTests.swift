import Foundation
import Testing
@testable import Sector_Zero

/// Milestone 47 — 765 command/result framing, floppy media geometry,
/// DMA-backed CHS reads, reset behavior, and IRQ6 completion ordering.
@MainActor
struct FloppyDiskControllerTests {
    private let sectorSize = 512

    private func image(
        tracks: Int = 40,
        heads: Int = 1,
        sectorsPerTrack: Int = 8
    ) -> Data {
        let sectorCount = tracks * heads * sectorsPerTrack
        var bytes: [UInt8] = []
        bytes.reserveCapacity(sectorCount * sectorSize)
        for logicalSector in 0..<sectorCount {
            bytes.append(contentsOf: repeatElement(
                UInt8(truncatingIfNeeded: logicalSector),
                count: sectorSize
            ))
        }
        return Data(bytes)
    }

    private func enable(_ machine: Machine) {
        machine.bus.writeIOByte(0x0C, at: 0x3F2)
    }

    private func writeCommand(_ bytes: [UInt8], to machine: Machine) {
        for byte in bytes {
            machine.bus.writeIOByte(byte, at: 0x3F5)
        }
    }

    private func readResult(_ count: Int, from machine: Machine) -> [UInt8] {
        (0..<count).map { _ in machine.bus.readIOByte(at: 0x3F5) }
    }

    private func drainResetSenseStatuses(_ machine: Machine) {
        for drive in 0..<4 {
            writeCommand([0x08], to: machine)
            #expect(readResult(2, from: machine) == [0xC0 | UInt8(drive), 0])
        }
    }

    private func programDMA(
        _ machine: Machine,
        address: UInt16,
        count: UInt16,
        page: UInt8 = 0
    ) {
        machine.bus.writeIOByte(0, at: 0x0C)
        machine.bus.writeIOByte(UInt8(truncatingIfNeeded: address), at: 0x04)
        machine.bus.writeIOByte(UInt8(address >> 8), at: 0x04)
        machine.bus.writeIOByte(UInt8(truncatingIfNeeded: count), at: 0x05)
        machine.bus.writeIOByte(UInt8(count >> 8), at: 0x05)
        machine.bus.writeIOByte(page, at: 0x81)
        machine.bus.writeIOByte(0x46, at: 0x0B) // Ch2, device-to-memory, single.
        machine.bus.writeIOByte(0x02, at: 0x0A) // Unmask channel 2.
    }

    private func readDataCommand(
        cylinder: UInt8,
        head: UInt8,
        sector: UInt8,
        endOfTrack: UInt8
    ) -> [UInt8] {
        [0x06, head << 2, cylinder, head, sector, 2, endOfTrack, 0x1B, 0xFF]
    }

    @Test("Known raw floppy sizes map to deterministic geometry")
    func geometryDetection() throws {
        let geometries = try FloppyDiskGeometry.supported.map {
            try FloppyDiskGeometry.detect(byteCount: $0.byteCount)
        }

        #expect(geometries == FloppyDiskGeometry.supported)
        #expect(throws: FloppyDiskImageError.unsupportedSize(123_456)) {
            try FloppyDiskGeometry.detect(byteCount: 123_456)
        }
    }

    @Test("Reset release and command/result phases are visible through PC ports")
    func commandStateMachine() {
        let machine = Machine()
        #expect(machine.bus.readIOByte(at: 0x3F4) == 0x80)
        #expect(machine.bus.readIOByte(at: 0x3F7) == 0x80)

        enable(machine)
        #expect(machine.snapshot().floppyController.pendingInterruptCount == 4)
        #expect(machine.snapshot().interruptController.assertedLines & 0x40 == 0x40)
        drainResetSenseStatuses(machine)
        #expect(machine.snapshot().floppyController.phase == .idle)

        writeCommand([0x0F], to: machine)
        #expect(machine.snapshot().floppyController.phase == .command)
        writeCommand([0x04, 0x12], to: machine)
        #expect(machine.snapshot().floppyController.phase == .idle)
        writeCommand([0x08], to: machine)
        #expect(readResult(2, from: machine) == [0x24, 0x12])

        writeCommand([0x1F], to: machine)
        #expect(machine.bus.readIOByte(at: 0x3F4) == 0xD1)
        #expect(readResult(1, from: machine) == [0x80])
    }

    @Test("A CHS sector read reaches RAM through DMA before IRQ6 is raised")
    func dmaReadAndInterruptOrdering() throws {
        let machine = Machine()
        try machine.bus.loadBytes([0xF4], at: 0xFFFF0)
        machine.step()
        #expect(machine.cpu.halted)
        let startingCycles = machine.cycleCount
        try machine.mountFloppyDisk(image())
        enable(machine)
        drainResetSenseStatuses(machine)
        programDMA(machine, address: 0x2000, count: 511)
        writeCommand(
            readDataCommand(cylinder: 2, head: 0, sector: 3, endOfTrack: 3),
            to: machine
        )

        #expect(machine.snapshot().floppyController.phase == .execution)
        #expect(machine.snapshot().floppyController.dmaRequestActive)
        #expect(machine.snapshot().interruptController.assertedLines & 0x40 == 0)

        for _ in 0..<511 { machine.step() }
        #expect(machine.snapshot().floppyController.phase == .execution)
        #expect(machine.snapshot().interruptController.assertedLines & 0x40 == 0)

        machine.step()
        let snapshot = machine.snapshot()
        #expect(snapshot.floppyController.phase == .result)
        #expect(!snapshot.floppyController.dmaRequestActive)
        #expect(snapshot.interruptController.assertedLines & 0x40 == 0x40)
        #expect(snapshot.dmaController.channel2.terminalCount)
        #expect(snapshot.dmaController.channel2.masked)
        #expect(snapshot.cycleCount == startingCycles + UInt64(512 * 4))
        #expect(snapshot.floppyController.recentReads == [FloppyReadTrace(
            cylinder: 2,
            head: 0,
            sector: 3,
            endOfTrack: 3,
            dmaAddress: 0x2000,
            byteCount: 512
        )])

        let expectedLogicalSector = (2 * 8) + 2
        #expect((0..<sectorSize).allSatisfy {
            machine.bus.readByte(at: UInt32(0x2000 + $0)) == UInt8(expectedLogicalSector)
        })
        #expect(readResult(7, from: machine) == [0, 0, 0, 2, 0, 3, 2])
        #expect(machine.snapshot().floppyController.phase == .idle)

        machine.reset()
        #expect(machine.snapshot().floppyController.recentReads.isEmpty)
    }

    @Test("READ ID reports deterministic media geometry through a standard command")
    func readID() throws {
        let machine = Machine()
        try machine.mountFloppyDisk(image(tracks: 40, heads: 2, sectorsPerTrack: 9))
        enable(machine)
        drainResetSenseStatuses(machine)

        writeCommand([0x0A, 0x04], to: machine)
        #expect(readResult(7, from: machine) == [0x04, 0, 0, 0, 1, 9, 2])

        writeCommand([0x0F, 0x00, 79], to: machine)
        writeCommand([0x08], to: machine)
        _ = readResult(2, from: machine)
        writeCommand([0x0A, 0x00], to: machine)
        let invalid = readResult(7, from: machine)
        #expect(invalid[0] & 0x40 == 0x40)
        #expect(invalid[2] & 0x10 == 0x10)
    }

    @Test("Missing media and invalid end-of-track complete with 765 error results")
    func mediaAndBoundsErrors() throws {
        let machine = Machine()
        enable(machine)
        drainResetSenseStatuses(machine)

        writeCommand(
            readDataCommand(cylinder: 0, head: 0, sector: 1, endOfTrack: 1),
            to: machine
        )
        #expect(readResult(7, from: machine) == [0x48, 0x04, 0, 0, 0, 1, 2])

        try machine.mountFloppyDisk(image())
        writeCommand(
            readDataCommand(cylinder: 0, head: 0, sector: 8, endOfTrack: 9),
            to: machine
        )
        #expect(readResult(7, from: machine) == [0x40, 0x84, 0, 0, 0, 8, 2])

        writeCommand(
            readDataCommand(cylinder: 40, head: 0, sector: 1, endOfTrack: 1),
            to: machine
        )
        #expect(readResult(7, from: machine) == [0x40, 0x04, 0x10, 40, 0, 1, 2])
    }

    @Test("Controller reset preserves mounted media and eject clears it")
    func resetAndEject() throws {
        let machine = Machine()
        try machine.mountFloppyDisk(image())
        enable(machine)
        writeCommand([0x0F, 0, 7], to: machine)
        #expect(machine.snapshot().floppyController.currentCylinder == 7)

        machine.reset()
        var snapshot = machine.snapshot().floppyController
        #expect(snapshot.phase == .idle)
        #expect(snapshot.digitalOutput == 0)
        #expect(snapshot.currentCylinder == 0)
        #expect(snapshot.mediaByteCount == 163_840)
        #expect(snapshot.mediaGeometry == FloppyDiskGeometry(
            tracks: 40,
            heads: 1,
            sectorsPerTrack: 8,
            bytesPerSector: 512
        ))
        machine.ejectFloppyDisk()
        snapshot = machine.snapshot().floppyController
        #expect(snapshot.mediaGeometry == nil)
        #expect(snapshot.mediaByteCount == 0)
    }
}
