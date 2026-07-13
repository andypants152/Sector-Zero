import Foundation

enum IRQLine: UInt8, CaseIterable, Sendable {
    case timer = 0
    case keyboard = 1
    case cascade = 2
    case serial2 = 3
    case serial1 = 4
    case parallel2 = 5
    case floppy = 6
    case parallel1 = 7
}

enum PICReadRegister: Equatable, Sendable {
    case interruptRequest
    case inService
}

struct ProgrammableInterruptControllerSnapshot: Equatable, Sendable {
    let initialized: Bool
    let vectorBase: UInt8
    let interruptMask: UInt8
    let interruptRequest: UInt8
    let inService: UInt8
    let assertedLines: UInt8
    let levelTriggered: Bool
    let autoEOI: Bool
    let readRegister: PICReadRegister
}

/// The PC/XT master 8259A. Fixed priority is IRQ0 (highest) through IRQ7;
/// rotation and a cascaded slave are deliberately deferred until required.
final class ProgrammableInterruptController: IOPortDevice {
    static let commandPort: UInt16 = 0x20
    static let dataPort: UInt16 = 0x21

    private enum InitializationStep {
        case idle
        case icw2
        case icw3
        case icw4
    }

    private var initializationStep = InitializationStep.idle
    private var requiresICW3 = false
    private var requiresICW4 = false
    private(set) var initialized = false
    private(set) var vectorBase: UInt8 = 0x08
    private(set) var interruptMask: UInt8 = 0xFF
    private(set) var interruptRequest: UInt8 = 0
    private(set) var inService: UInt8 = 0
    private(set) var assertedLines: UInt8 = 0
    private(set) var levelTriggered = false
    private(set) var autoEOI = false
    private(set) var readRegister = PICReadRegister.interruptRequest

    var snapshot: ProgrammableInterruptControllerSnapshot {
        ProgrammableInterruptControllerSnapshot(
            initialized: initialized,
            vectorBase: vectorBase,
            interruptMask: interruptMask,
            interruptRequest: interruptRequest,
            inService: inService,
            assertedLines: assertedLines,
            levelTriggered: levelTriggered,
            autoEOI: autoEOI,
            readRegister: readRegister
        )
    }

    var hasPendingInterrupt: Bool {
        highestPendingIRQ() != nil
    }

    func reset() {
        initializationStep = .idle
        requiresICW3 = false
        requiresICW4 = false
        initialized = false
        vectorBase = 0x08
        interruptMask = 0xFF
        interruptRequest = 0
        inService = 0
        assertedLines = 0
        levelTriggered = false
        autoEOI = false
        readRegister = .interruptRequest
    }

    func raise(_ line: IRQLine) {
        let bit = UInt8(1 << line.rawValue)
        let wasAsserted = assertedLines & bit != 0
        assertedLines |= bit
        if levelTriggered || !wasAsserted {
            interruptRequest |= bit
        }
    }

    func lower(_ line: IRQLine) {
        let bit = UInt8(1 << line.rawValue)
        assertedLines &= ~bit
        if levelTriggered {
            interruptRequest &= ~bit
        }
    }

    /// Completes the two INTA cycles conceptually and returns the vector placed
    /// on the data bus. A request is moved from IRR to ISR unless auto-EOI is on.
    func acknowledge() -> UInt8? {
        guard let irq = highestPendingIRQ() else { return nil }
        let bit = UInt8(1 << irq)
        interruptRequest &= ~bit
        if !autoEOI {
            inService |= bit
        } else if levelTriggered, assertedLines & bit != 0 {
            interruptRequest |= bit
        }
        return vectorBase &+ irq
    }

    func readByte(from port: UInt16) -> UInt8 {
        switch port {
        case Self.commandPort:
            return readRegister == .interruptRequest ? interruptRequest : inService
        case Self.dataPort:
            return interruptMask
        default:
            return 0xFF
        }
    }

    func writeByte(_ value: UInt8, to port: UInt16) {
        switch port {
        case Self.commandPort:
            writeCommand(value)
        case Self.dataPort:
            writeData(value)
        default:
            break
        }
    }

    private func writeCommand(_ value: UInt8) {
        if value & 0x10 != 0 {
            // ICW1 begins a fresh initialization sequence.
            initialized = false
            interruptRequest = 0
            inService = 0
            interruptMask = 0
            levelTriggered = value & 0x08 != 0
            requiresICW3 = value & 0x02 == 0
            requiresICW4 = value & 0x01 != 0
            autoEOI = false
            initializationStep = .icw2
            return
        }

        // OCW3: RR/RIS select whether command-port reads expose IRR or ISR.
        if value & 0x18 == 0x08, value & 0x02 != 0 {
            readRegister = value & 0x01 == 0 ? .interruptRequest : .inService
            return
        }

        // OCW2 EOI. Rotation commands intentionally retain fixed priority.
        guard value & 0x20 != 0 else { return }
        if value & 0x40 != 0 {
            endOfInterrupt(irq: value & 0x07)
        } else if let irq = highestSetBitByPriority(inService) {
            endOfInterrupt(irq: irq)
        }
    }

    private func writeData(_ value: UInt8) {
        switch initializationStep {
        case .idle:
            interruptMask = value
        case .icw2:
            vectorBase = value & 0xF8
            if requiresICW3 {
                initializationStep = .icw3
            } else if requiresICW4 {
                initializationStep = .icw4
            } else {
                finishInitialization()
            }
        case .icw3:
            // The master cascade bitmap is consumed for register compatibility;
            // a slave PIC is outside the current machine topology.
            if requiresICW4 {
                initializationStep = .icw4
            } else {
                finishInitialization()
            }
        case .icw4:
            autoEOI = value & 0x02 != 0
            finishInitialization()
        }
    }

    private func finishInitialization() {
        initialized = true
        initializationStep = .idle
        refreshLevelRequests()
    }

    private func endOfInterrupt(irq: UInt8) {
        let bit = UInt8(1 << irq)
        inService &= ~bit
        if levelTriggered, assertedLines & bit != 0 {
            interruptRequest |= bit
        }
    }

    private func refreshLevelRequests() {
        guard levelTriggered else { return }
        interruptRequest |= assertedLines & ~inService
    }

    private func highestPendingIRQ() -> UInt8? {
        let eligible = interruptRequest & ~interruptMask
        guard let candidate = highestSetBitByPriority(eligible) else { return nil }
        guard let active = highestSetBitByPriority(inService) else { return candidate }
        return candidate < active ? candidate : nil
    }

    private func highestSetBitByPriority(_ value: UInt8) -> UInt8? {
        for irq in UInt8(0)...UInt8(7) where value & UInt8(1 << irq) != 0 {
            return irq
        }
        return nil
    }
}
