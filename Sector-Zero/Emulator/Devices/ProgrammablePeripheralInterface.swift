import Foundation

struct ProgrammablePeripheralInterfaceSnapshot: Equatable, Sendable {
    let portBRegister: UInt8
    let controlRegister: UInt8
    let latchedScanCode: UInt8?
    let pendingScanCodeCount: Int
    let overrunCount: Int
    let keyboardClockEnabled: Bool
    let keyboardClearHeld: Bool
}

/// Minimal Intel 8255-compatible PPI as wired on the IBM PC/XT: port A latches
/// keyboard scan codes, port B carries the keyboard and speaker control bits,
/// and port C mirrors timer channel-2 output. Only the XT operating
/// configuration is modeled (control 99h — ports A and C input, B output);
/// DIP switches and parity lines are not modeled and read 0.
final class ProgrammablePeripheralInterface: IOPortDevice {
    static let portA: UInt16 = 0x60
    static let portB: UInt16 = 0x61
    static let portC: UInt16 = 0x62
    static let controlPort: UInt16 = 0x63

    /// Scan codes buffered behind the latch. Matches the order of magnitude
    /// of the real keyboard's internal buffer; overflow drops the newest code
    /// and counts an overrun, so earlier keystrokes are never reordered.
    static let scanCodeQueueCapacity = 16

    /// Intentional deviation from the 8255's all-zero reset: the keyboard
    /// clock starts enabled so machines without firmware still deliver
    /// keystrokes; firmware remains free to reprogram port B.
    private static let portBResetValue: UInt8 = 0x40
    private static let xtOperatingControlValue: UInt8 = 0x99

    private let interruptController: ProgrammableInterruptController
    private let intervalTimer: ProgrammableIntervalTimer

    private(set) var portBRegister = ProgrammablePeripheralInterface.portBResetValue
    private(set) var controlRegister = ProgrammablePeripheralInterface.xtOperatingControlValue
    private(set) var latchedScanCode: UInt8?
    private var pendingScanCodes: [UInt8] = []
    private(set) var overrunCount = 0

    init(
        interruptController: ProgrammableInterruptController,
        intervalTimer: ProgrammableIntervalTimer
    ) {
        self.interruptController = interruptController
        self.intervalTimer = intervalTimer
    }

    var keyboardClockEnabled: Bool { portBRegister & 0x40 != 0 }
    var keyboardClearHeld: Bool { portBRegister & 0x80 != 0 }

    var snapshot: ProgrammablePeripheralInterfaceSnapshot {
        ProgrammablePeripheralInterfaceSnapshot(
            portBRegister: portBRegister,
            controlRegister: controlRegister,
            latchedScanCode: latchedScanCode,
            pendingScanCodeCount: pendingScanCodes.count,
            overrunCount: overrunCount,
            keyboardClockEnabled: keyboardClockEnabled,
            keyboardClearHeld: keyboardClearHeld
        )
    }

    /// Accepts one raw byte exactly as the XT keyboard's serial line would
    /// deliver it — break codes already carry bit 7. Must only be called from
    /// the execution context; host threads go through `Machine.postScanCode`.
    func receiveScanCode(_ code: UInt8) {
        guard pendingScanCodes.count < Self.scanCodeQueueCapacity else {
            overrunCount += 1
            return
        }
        pendingScanCodes.append(code)
        deliverPendingScanCodeIfPossible()
    }

    func readByte(from port: UInt16) -> UInt8 {
        switch port {
        case Self.portA:
            return latchedScanCode ?? 0
        case Self.portB:
            return portBRegister
        case Self.portC:
            return intervalTimer.channel2Output ? 0x20 : 0
        case Self.controlPort:
            return controlRegister
        default:
            return 0xFF
        }
    }

    func writeByte(_ value: UInt8, to port: UInt16) {
        switch port {
        case Self.portB:
            portBRegister = value
            intervalTimer.setChannel2Gate(value & 0x01 != 0)
            intervalTimer.setChannel2SpeakerEnabled(value & 0x02 != 0)
            if keyboardClearHeld {
                // Acknowledge: the latch drops and IRQ1 is withdrawn while
                // the clear bit stays high.
                latchedScanCode = nil
                interruptController.lower(.keyboard)
            } else {
                deliverPendingScanCodeIfPossible()
            }
        case Self.controlPort:
            controlRegister = value
        default:
            break // Ports A and C are inputs in the XT configuration.
        }
    }

    func reset() {
        portBRegister = Self.portBResetValue
        controlRegister = Self.xtOperatingControlValue
        latchedScanCode = nil
        pendingScanCodes.removeAll()
        overrunCount = 0
    }

    private func deliverPendingScanCodeIfPossible() {
        guard latchedScanCode == nil,
              keyboardClockEnabled,
              !keyboardClearHeld,
              !pendingScanCodes.isEmpty else {
            return
        }
        latchedScanCode = pendingScanCodes.removeFirst()
        interruptController.raise(.keyboard)
    }
}
