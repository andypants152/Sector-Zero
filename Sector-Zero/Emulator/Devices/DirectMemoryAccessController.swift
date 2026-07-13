import Foundation

enum DMATransferDirection: Equatable, Sendable {
    case verify
    case deviceToMemory
    case memoryToDevice
}

struct DMAChannelSnapshot: Equatable, Sendable {
    let baseAddress: UInt16
    let currentAddress: UInt16
    let baseCount: UInt16
    let currentCount: UInt16
    let page: UInt8
    let mode: UInt8
    let direction: DMATransferDirection
    let masked: Bool
    let requestActive: Bool
    let terminalCount: Bool

    var physicalAddress: UInt32 {
        UInt32(page & 0x0F) << 16 | UInt32(currentAddress)
    }
}

struct DirectMemoryAccessControllerSnapshot: Equatable, Sendable {
    let command: UInt8
    let status: UInt8
    let lowByteNext: Bool
    let channel2: DMAChannelSnapshot
}

struct DMAServiceResult: Equatable, Sendable {
    let transferred: Bool
    let physicalAddress: UInt32?
    let value: UInt8?
    let direction: DMATransferDirection?
    let reachedTerminalCount: Bool
    let clocks: Int

    static let inactive = DMAServiceResult(
        transferred: false,
        physicalAddress: nil,
        value: nil,
        direction: nil,
        reachedTerminalCount: false,
        clocks: 0
    )
}

/// Intel 8237A subset wired for the original PC's floppy DMA channel (channel
/// 2). The other channel register ports remain open bus and their masks stay
/// asserted. Each service call performs at most one byte transfer, matching the
/// floppy controller's single-transfer DREQ handshake.
final class DirectMemoryAccessController: IOPortDevice {
    static let registerPorts: ClosedRange<UInt16> = 0x00...0x0F
    static let channel2AddressPort: UInt16 = 0x04
    static let channel2CountPort: UInt16 = 0x05
    static let statusCommandPort: UInt16 = 0x08
    static let requestPort: UInt16 = 0x09
    static let singleMaskPort: UInt16 = 0x0A
    static let modePort: UInt16 = 0x0B
    static let clearBytePointerPort: UInt16 = 0x0C
    static let masterClearPort: UInt16 = 0x0D
    static let clearMaskPort: UInt16 = 0x0E
    static let allMaskPort: UInt16 = 0x0F
    static let channel2PagePort: UInt16 = 0x81
    static let clocksPerByte = 4

    private var baseAddress: UInt16 = 0
    private var currentAddress: UInt16 = 0
    private var baseCount: UInt16 = 0
    private var currentCount: UInt16 = 0
    private var page: UInt8 = 0
    private var mode: UInt8 = 0
    private var command: UInt8 = 0
    private var channel2Masked = true
    private var softwareRequest = false
    private var hardwareRequest = false
    private var terminalCountBits: UInt8 = 0
    private var lowByteNext = true

    var snapshot: DirectMemoryAccessControllerSnapshot {
        DirectMemoryAccessControllerSnapshot(
            command: command,
            status: statusValue,
            lowByteNext: lowByteNext,
            channel2: DMAChannelSnapshot(
                baseAddress: baseAddress,
                currentAddress: currentAddress,
                baseCount: baseCount,
                currentCount: currentCount,
                page: page,
                mode: mode,
                direction: transferDirection,
                masked: channel2Masked,
                requestActive: requestActive,
                terminalCount: terminalCountBits & 0x04 != 0
            )
        )
    }

    var canServiceChannel2: Bool {
        command & 0x04 == 0
            && !channel2Masked
            && requestActive
            && mode & 0x03 == 0x02
            && mode & 0x30 == 0
            && mode & 0xC0 == 0x40
    }

    func reset() {
        baseAddress = 0
        currentAddress = 0
        baseCount = 0
        currentCount = 0
        page = 0
        mode = 0
        command = 0
        channel2Masked = true
        softwareRequest = false
        hardwareRequest = false
        terminalCountBits = 0
        lowByteNext = true
    }

    /// Models the level on channel 2's external DREQ pin. The device owns this
    /// level; terminal count clears a software request but does not invent a
    /// falling hardware edge on the device's behalf.
    func setChannel2HardwareRequest(_ active: Bool) {
        hardwareRequest = active
    }

    func serviceChannel2(
        memoryRead: (UInt32) -> UInt8,
        memoryWrite: (UInt8, UInt32) -> Void,
        deviceRead: () -> UInt8,
        deviceWrite: (UInt8) -> Void
    ) -> DMAServiceResult {
        guard canServiceChannel2 else {
            return .inactive
        }

        let address = UInt32(page & 0x0F) << 16 | UInt32(currentAddress)
        let direction = transferDirection
        let value: UInt8?
        switch direction {
        case .verify:
            value = nil
        case .deviceToMemory:
            let byte = deviceRead()
            value = byte
            memoryWrite(byte, address)
        case .memoryToDevice:
            let byte = memoryRead(address)
            value = byte
            deviceWrite(byte)
        }

        let reachedTerminalCount = currentCount == 0
        currentAddress &+= 1 // Wraps within the fixed 64 KiB page.
        currentCount &-= 1
        if reachedTerminalCount {
            terminalCountBits |= 0x04
            softwareRequest = false
            // Internal EOP masks a non-auto-initializing 8237A channel. This
            // prevents a peripheral that has not lowered DREQ yet from moving
            // bytes beyond the guest-programmed buffer.
            channel2Masked = true
        }

        return DMAServiceResult(
            transferred: true,
            physicalAddress: address,
            value: value,
            direction: direction,
            reachedTerminalCount: reachedTerminalCount,
            clocks: Self.clocksPerByte
        )
    }

    func readByte(from port: UInt16) -> UInt8 {
        switch port {
        case Self.channel2AddressPort:
            return readRegisterByte(currentAddress)
        case Self.channel2CountPort:
            return readRegisterByte(currentCount)
        case Self.statusCommandPort:
            let value = statusValue
            terminalCountBits = 0
            return value
        case Self.channel2PagePort:
            return page
        default:
            return 0xFF
        }
    }

    func writeByte(_ value: UInt8, to port: UInt16) {
        switch port {
        case Self.channel2AddressPort:
            writeAddressByte(value)
        case Self.channel2CountPort:
            writeCountByte(value)
        case Self.statusCommandPort:
            command = value
        case Self.requestPort:
            guard value & 0x03 == 0x02 else { return }
            softwareRequest = value & 0x04 != 0
        case Self.singleMaskPort:
            guard value & 0x03 == 0x02 else { return }
            channel2Masked = value & 0x04 != 0
        case Self.modePort:
            guard value & 0x03 == 0x02 else { return }
            mode = value
        case Self.clearBytePointerPort:
            lowByteNext = true
        case Self.masterClearPort:
            masterClear()
        case Self.clearMaskPort:
            channel2Masked = false
        case Self.allMaskPort:
            channel2Masked = value & 0x04 != 0
        case Self.channel2PagePort:
            page = value
        default:
            break
        }
    }

    private var requestActive: Bool {
        softwareRequest || hardwareRequest
    }

    private var statusValue: UInt8 {
        terminalCountBits | (requestActive ? 0x40 : 0)
    }

    private var transferDirection: DMATransferDirection {
        switch mode & 0x0C {
        case 0x04: .deviceToMemory
        case 0x08: .memoryToDevice
        default: .verify
        }
    }

    private func readRegisterByte(_ register: UInt16) -> UInt8 {
        let value = lowByteNext
            ? UInt8(truncatingIfNeeded: register)
            : UInt8(register >> 8)
        lowByteNext.toggle()
        return value
    }

    private func writeAddressByte(_ value: UInt8) {
        if lowByteNext {
            baseAddress = baseAddress & 0xFF00 | UInt16(value)
            currentAddress = currentAddress & 0xFF00 | UInt16(value)
        } else {
            baseAddress = baseAddress & 0x00FF | UInt16(value) << 8
            currentAddress = currentAddress & 0x00FF | UInt16(value) << 8
        }
        lowByteNext.toggle()
    }

    private func writeCountByte(_ value: UInt8) {
        if lowByteNext {
            baseCount = baseCount & 0xFF00 | UInt16(value)
            currentCount = currentCount & 0xFF00 | UInt16(value)
        } else {
            baseCount = baseCount & 0x00FF | UInt16(value) << 8
            currentCount = currentCount & 0x00FF | UInt16(value) << 8
        }
        lowByteNext.toggle()
    }

    private func masterClear() {
        command = 0
        softwareRequest = false
        hardwareRequest = false
        terminalCountBits = 0
        channel2Masked = true
        lowByteNext = true
    }
}
