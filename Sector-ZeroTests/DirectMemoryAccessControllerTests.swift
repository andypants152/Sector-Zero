import Testing
@testable import Sector_Zero

/// Milestone 46 — 8237A channel-2 register programming, floppy-direction byte
/// transfers, terminal count, fixed-page wrapping, masks/requests, and clocks.
@MainActor
struct DirectMemoryAccessControllerTests {
    private func programChannel2(
        _ machine: Machine,
        address: UInt16,
        count: UInt16,
        page: UInt8,
        mode: UInt8
    ) {
        machine.bus.writeIOByte(0, at: 0x0C) // Clear low/high byte pointer.
        machine.bus.writeIOByte(UInt8(truncatingIfNeeded: address), at: 0x04)
        machine.bus.writeIOByte(UInt8(address >> 8), at: 0x04)
        machine.bus.writeIOByte(UInt8(truncatingIfNeeded: count), at: 0x05)
        machine.bus.writeIOByte(UInt8(count >> 8), at: 0x05)
        machine.bus.writeIOByte(page, at: 0x81)
        machine.bus.writeIOByte(mode, at: 0x0B)
    }

    private func unmaskChannel2(_ machine: Machine) {
        machine.bus.writeIOByte(0x02, at: 0x0A)
    }

    @Test("Channel 2 address, count, page, mode, and byte pointer program through PC ports")
    func registerProgramming() {
        let machine = Machine()
        programChannel2(machine, address: 0x1234, count: 0x0102, page: 0x0A, mode: 0x46)
        unmaskChannel2(machine)

        let channel = machine.snapshot().dmaController.channel2
        #expect(channel.baseAddress == 0x1234)
        #expect(channel.currentAddress == 0x1234)
        #expect(channel.baseCount == 0x0102)
        #expect(channel.currentCount == 0x0102)
        #expect(channel.page == 0x0A)
        #expect(channel.mode == 0x46)
        #expect(channel.direction == .deviceToMemory)
        #expect(channel.physicalAddress == 0xA1234)
        #expect(!channel.masked)
        #expect(machine.snapshot().dmaController.lowByteNext)

        machine.bus.writeIOByte(0, at: 0x0C)
        #expect(machine.bus.readIOByte(at: 0x04) == 0x34)
        #expect(machine.bus.readIOByte(at: 0x04) == 0x12)
        #expect(machine.bus.readIOByte(at: 0x81) == 0x0A)
        #expect(machine.bus.readIOByte(at: 0x00) == 0xFF) // Unimplemented channel 0.
    }

    @Test("Device-to-memory transfers use programmed count-minus-one terminal semantics")
    func deviceToMemory() {
        let machine = Machine()
        programChannel2(machine, address: 0x0100, count: 1, page: 0, mode: 0x46)
        unmaskChannel2(machine)
        machine.dmaController.setChannel2HardwareRequest(true)
        var bytes: [UInt8] = [0xAA, 0xBB]

        let first = machine.serviceDMAChannel2(deviceRead: { bytes.removeFirst() })
        let second = machine.serviceDMAChannel2(deviceRead: { bytes.removeFirst() })

        #expect(first.physicalAddress == 0x00100)
        #expect(first.direction == .deviceToMemory)
        #expect(!first.reachedTerminalCount)
        #expect(second.physicalAddress == 0x00101)
        #expect(second.reachedTerminalCount)
        #expect(machine.bus.readByte(at: 0x00100) == 0xAA)
        #expect(machine.bus.readByte(at: 0x00101) == 0xBB)
        #expect(machine.dmaController.snapshot.channel2.currentAddress == 0x0102)
        #expect(machine.dmaController.snapshot.channel2.currentCount == 0xFFFF)
        #expect(machine.dmaController.snapshot.channel2.masked)

        let afterTerminalCount = machine.serviceDMAChannel2(deviceRead: { 0xCC })
        #expect(!afterTerminalCount.transferred)
        #expect(machine.bus.readByte(at: 0x00102) == 0)
        #expect(machine.cycleCount == 8)

        let status = machine.bus.readIOByte(at: 0x08)
        #expect(status & 0x04 == 0x04) // Channel 2 terminal count.
        #expect(status & 0x40 == 0x40) // Hardware DREQ remains asserted.
        #expect(machine.bus.readIOByte(at: 0x08) & 0x04 == 0) // TC clears on read.
    }

    @Test("Memory-to-device transfers read through the normal system bus")
    func memoryToDevice() throws {
        let machine = Machine()
        try machine.bus.loadBytes([0x31, 0x32, 0x33], at: 0x20700)
        programChannel2(machine, address: 0x0700, count: 2, page: 2, mode: 0x4A)
        unmaskChannel2(machine)
        machine.dmaController.setChannel2HardwareRequest(true)
        var received: [UInt8] = []

        for _ in 0..<3 {
            machine.serviceDMAChannel2(deviceWrite: { received.append($0) })
        }

        #expect(received == [0x31, 0x32, 0x33])
        #expect(machine.dmaController.snapshot.channel2.direction == .memoryToDevice)
        #expect(machine.dmaController.snapshot.channel2.terminalCount)
    }

    @Test("Verify mode advances channel state without moving a data byte")
    func verifyTransfer() {
        let machine = Machine()
        programChannel2(machine, address: 0x0500, count: 0, page: 1, mode: 0x42)
        unmaskChannel2(machine)
        machine.bus.writeIOByte(0x06, at: 0x09) // Software request, channel 2.
        var touchedDevice = false

        let result = machine.serviceDMAChannel2(
            deviceRead: {
                touchedDevice = true
                return 0xAA
            },
            deviceWrite: { _ in touchedDevice = true }
        )

        #expect(result.transferred)
        #expect(result.direction == .verify)
        #expect(result.value == nil)
        #expect(result.reachedTerminalCount)
        #expect(!touchedDevice)
        #expect(!machine.dmaController.snapshot.channel2.requestActive)
        #expect(machine.dmaController.snapshot.channel2.currentAddress == 0x0501)
        #expect(machine.cycleCount == 4)
    }

    @Test("Address rollover wraps inside the programmed DMA page")
    func sixtyFourKiBBoundary() {
        let machine = Machine()
        programChannel2(machine, address: 0xFFFF, count: 1, page: 3, mode: 0x46)
        unmaskChannel2(machine)
        machine.dmaController.setChannel2HardwareRequest(true)
        var bytes: [UInt8] = [0xA5, 0x5A]

        let beforeWrap = machine.serviceDMAChannel2(deviceRead: { bytes.removeFirst() })
        let afterWrap = machine.serviceDMAChannel2(deviceRead: { bytes.removeFirst() })

        #expect(beforeWrap.physicalAddress == 0x3FFFF)
        #expect(afterWrap.physicalAddress == 0x30000)
        #expect(machine.bus.readByte(at: 0x3FFFF) == 0xA5)
        #expect(machine.bus.readByte(at: 0x30000) == 0x5A)
        #expect(machine.dmaController.snapshot.channel2.currentAddress == 1)
    }

    @Test("Masks, hardware/software requests, and controller disable gate service")
    func masksAndRequests() {
        let machine = Machine()
        programChannel2(machine, address: 0x0200, count: 0, page: 0, mode: 0x46)

        machine.dmaController.setChannel2HardwareRequest(true)
        #expect(machine.dmaController.snapshot.channel2.requestActive)
        #expect(!machine.serviceDMAChannel2(deviceRead: { 0x11 }).transferred)

        machine.bus.writeIOByte(0, at: 0x0E) // Clear all mask bits.
        machine.bus.writeIOByte(0x04, at: 0x08) // Disable the controller.
        #expect(!machine.serviceDMAChannel2(deviceRead: { 0x22 }).transferred)
        machine.bus.writeIOByte(0, at: 0x08)
        #expect(machine.serviceDMAChannel2(deviceRead: { 0x33 }).transferred)

        machine.dmaController.setChannel2HardwareRequest(false)
        machine.bus.writeIOByte(0x06, at: 0x09) // Set software request, channel 2.
        #expect(machine.bus.readIOByte(at: 0x08) & 0x40 == 0x40)
        machine.bus.writeIOByte(0x02, at: 0x09) // Clear software request.
        #expect(machine.bus.readIOByte(at: 0x08) & 0x40 == 0)

        machine.bus.writeIOByte(0x04, at: 0x0F) // Write all mask bits.
        #expect(machine.dmaController.snapshot.channel2.masked)
    }

    @Test("Modes outside the floppy single/increment/non-auto-init subset stay inactive")
    func unsupportedModes() {
        let machine = Machine()
        unmaskChannel2(machine)
        machine.dmaController.setChannel2HardwareRequest(true)

        for mode: UInt8 in [0x06, 0x56, 0x66, 0x86, 0xC6] {
            machine.bus.writeIOByte(mode, at: 0x0B)
            #expect(!machine.serviceDMAChannel2(deviceRead: { 0xAA }).transferred)
        }
        #expect(machine.cycleCount == 0)
    }

    @Test("Machine reset and DMA master clear restore masked idle state")
    func resetDefaults() {
        let machine = Machine()
        programChannel2(machine, address: 0x4321, count: 7, page: 5, mode: 0x46)
        unmaskChannel2(machine)
        machine.bus.writeIOByte(0x06, at: 0x09)
        machine.bus.writeIOByte(0, at: 0x0D) // Master clear preserves channel registers.

        var snapshot = machine.dmaController.snapshot
        #expect(snapshot.command == 0)
        #expect(snapshot.lowByteNext)
        #expect(snapshot.channel2.masked)
        #expect(!snapshot.channel2.requestActive)
        #expect(snapshot.channel2.currentAddress == 0x4321)

        machine.reset()
        snapshot = machine.dmaController.snapshot
        #expect(snapshot.channel2.baseAddress == 0)
        #expect(snapshot.channel2.currentAddress == 0)
        #expect(snapshot.channel2.baseCount == 0)
        #expect(snapshot.channel2.currentCount == 0)
        #expect(snapshot.channel2.page == 0)
        #expect(snapshot.channel2.mode == 0)
        #expect(snapshot.channel2.masked)
        #expect(!snapshot.channel2.requestActive)
    }

    @Test("Every serviced byte deterministically charges four machine clocks")
    func cycleAccounting() {
        let machine = Machine()
        programChannel2(machine, address: 0, count: 2, page: 0, mode: 0x46)
        unmaskChannel2(machine)
        machine.dmaController.setChannel2HardwareRequest(true)

        #expect(machine.serviceDMAChannel2(deviceRead: { 1 }).clocks == 4)
        #expect(machine.serviceDMAChannel2(deviceRead: { 2 }).clocks == 4)
        #expect(machine.serviceDMAChannel2(deviceRead: { 3 }).clocks == 4)
        #expect(machine.cycleCount == 12)

        machine.dmaController.setChannel2HardwareRequest(false)
        #expect(machine.serviceDMAChannel2(deviceRead: { 4 }).clocks == 0)
        #expect(machine.cycleCount == 12)
    }

    @Test("DMA writes obey ROM protection and retain its diagnostic")
    func memoryMapProtection() {
        let machine = Machine()
        programChannel2(machine, address: 0, count: 0, page: 0x0F, mode: 0x46)
        unmaskChannel2(machine)
        machine.dmaController.setChannel2HardwareRequest(true)

        let result = machine.serviceDMAChannel2(deviceRead: { 0xCC })

        #expect(result.transferred)
        #expect(result.physicalAddress == 0xF0000)
        #expect(machine.bus.readByte(at: 0xF0000) == 0xFF)
        #expect(machine.bus.lastMemoryMapError == .writeToReadOnly(0xF0000))
        #expect(machine.bus.rejectedROMWriteCount == 1)
        #expect(machine.cycleCount == 4)
    }
}
