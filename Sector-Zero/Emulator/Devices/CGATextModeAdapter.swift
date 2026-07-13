enum CGADisplayMode: Equatable, Sendable {
    case disabled
    case text80x25
    case unsupported
}

struct CGATextModeSnapshot: Equatable, Sendable {
    let displayMode: CGADisplayMode
    let columns: Int
    let rows: Int
    let cells: [ConsoleCell]
    let displayStartAddress: UInt16
    let cursorAddress: UInt16
    let cursorPosition: Int?
    let cursorStartLine: Int
    let cursorEndLine: Int
    let modeControl: UInt8
    let colorSelect: UInt8
    let status: UInt8
}

/// Minimal IBM CGA-compatible 80×25 text adapter. Graphics and 40-column modes
/// retain VRAM/register state but intentionally snapshot as unsupported.
final class CGATextModeAdapter: MemoryMappedDevice, IOPortDevice, ClockedDevice {
    static let memoryRange: ClosedRange<UInt32> = 0xB8000...0xBBFFF
    static let crtcIndexPort: UInt16 = 0x3D4
    static let crtcDataPort: UInt16 = 0x3D5
    static let modeControlPort: UInt16 = 0x3D8
    static let colorSelectPort: UInt16 = 0x3D9
    static let statusPort: UInt16 = 0x3DA
    static let columns = 80
    static let rows = 25

    private static let frameClocks = 79_545
    private static let verticalRetraceStart = 75_000
    private static let horizontalCharacterClocks = 304
    private static let horizontalDisplayClocks = 256

    private var videoMemory = CGATextModeAdapter.blankVideoMemory()
    private var crtcRegisters = Array(repeating: UInt8(0), count: 0x20)
    private var selectedCRTCRegister: UInt8 = 0
    private(set) var modeControl: UInt8 = 0
    private(set) var colorSelect: UInt8 = 0
    private var frameClock = 0

    var snapshot: CGATextModeSnapshot {
        let mode = displayMode
        let start = displayStartAddress
        let cursor = cursorAddress
        let relativeCursor = Int((cursor &- start) & 0x1FFF)
        let cursorDisabled = crtcRegisters[0x0A] & 0x20 != 0
        let cursorPosition = mode == .text80x25 && !cursorDisabled && relativeCursor < Self.columns * Self.rows
            ? relativeCursor
            : nil

        return CGATextModeSnapshot(
            displayMode: mode,
            columns: Self.columns,
            rows: Self.rows,
            cells: decodedCells(displayMode: mode, startAddress: start),
            displayStartAddress: start,
            cursorAddress: cursor,
            cursorPosition: cursorPosition,
            cursorStartLine: Int(crtcRegisters[0x0A] & 0x1F),
            cursorEndLine: Int(crtcRegisters[0x0B] & 0x1F),
            modeControl: modeControl,
            colorSelect: colorSelect,
            status: statusRegister
        )
    }

    func reset() {
        videoMemory = Self.blankVideoMemory()
        crtcRegisters = Array(repeating: 0, count: crtcRegisters.count)
        selectedCRTCRegister = 0
        modeControl = 0
        colorSelect = 0
        frameClock = 0
    }

    /// Hardware CGA RAM has undefined power-on contents. Use ordinary blank
    /// text cells for the emulator's deterministic reset state so firmware
    /// that enables text mode before clearing the screen does not expose a
    /// synthetic wall of unsupported code-point glyphs.
    private static func blankVideoMemory() -> [UInt8] {
        var memory = Array(repeating: UInt8(0), count: Int(memoryRange.count))
        for byteAddress in stride(from: 0, to: memory.count, by: 2) {
            memory[byteAddress] = 0x20
            memory[byteAddress + 1] = 0x07
        }
        return memory
    }

    func advance(by clocks: Int) {
        precondition(clocks >= 0, "CGA clock advance cannot be negative")
        frameClock = (frameClock + clocks % Self.frameClocks) % Self.frameClocks
    }

    func readByte(at offset: Int) -> UInt8 {
        guard videoMemory.indices.contains(offset) else { return 0xFF }
        return videoMemory[offset]
    }

    func writeByte(_ value: UInt8, at offset: Int) {
        guard videoMemory.indices.contains(offset) else { return }
        videoMemory[offset] = value
    }

    func readByte(from port: UInt16) -> UInt8 {
        switch port {
        case Self.crtcIndexPort:
            return selectedCRTCRegister
        case Self.crtcDataPort:
            return crtcRegisters[Int(selectedCRTCRegister & 0x1F)]
        case Self.modeControlPort:
            return modeControl
        case Self.colorSelectPort:
            return colorSelect
        case Self.statusPort:
            return statusRegister
        default:
            return 0xFF
        }
    }

    func writeByte(_ value: UInt8, to port: UInt16) {
        switch port {
        case Self.crtcIndexPort:
            selectedCRTCRegister = value & 0x1F
        case Self.crtcDataPort:
            crtcRegisters[Int(selectedCRTCRegister)] = value
        case Self.modeControlPort:
            modeControl = value
        case Self.colorSelectPort:
            colorSelect = value
        default:
            break
        }
    }

    private var displayMode: CGADisplayMode {
        guard modeControl & 0x08 != 0 else { return .disabled }
        let isGraphics = modeControl & 0x02 != 0
        let is80Columns = modeControl & 0x01 != 0
        return !isGraphics && is80Columns ? .text80x25 : .unsupported
    }

    private var displayStartAddress: UInt16 {
        (UInt16(crtcRegisters[0x0C]) << 8 | UInt16(crtcRegisters[0x0D])) & 0x3FFF
    }

    private var cursorAddress: UInt16 {
        (UInt16(crtcRegisters[0x0E]) << 8 | UInt16(crtcRegisters[0x0F])) & 0x3FFF
    }

    private var statusRegister: UInt8 {
        var status: UInt8 = 0
        let verticalRetrace = frameClock >= Self.verticalRetraceStart
        let horizontalDisplay = frameClock % Self.horizontalCharacterClocks < Self.horizontalDisplayClocks
        if verticalRetrace { status |= 0x08 }
        if !verticalRetrace, horizontalDisplay { status |= 0x01 }
        return status
    }

    private func decodedCells(displayMode: CGADisplayMode, startAddress: UInt16) -> [ConsoleCell] {
        guard displayMode == .text80x25 else {
            return Array(repeating: ConsoleCell(codePoint: 0, foreground: .black, background: .black), count: Self.columns * Self.rows)
        }
        let blinkEnabled = modeControl & 0x20 != 0
        return (0..<(Self.columns * Self.rows)).map { cellOffset in
            let wordAddress = (Int(startAddress) + cellOffset) & 0x1FFF
            let byteAddress = wordAddress * 2
            let character = videoMemory[byteAddress]
            let attribute = videoMemory[byteAddress + 1]
            let backgroundIndex = blinkEnabled ? (attribute >> 4) & 0x07 : (attribute >> 4) & 0x0F
            return ConsoleCell(
                codePoint: character,
                foreground: .cga(index: attribute & 0x0F),
                background: .cga(index: backgroundIndex),
                blink: blinkEnabled && attribute & 0x80 != 0
            )
        }
    }
}

extension ConsoleColor {
    static func cga(index: UInt8) -> ConsoleColor {
        switch index & 0x0F {
        case 0x0: .black
        case 0x1: .blue
        case 0x2: .green
        case 0x3: .cyan
        case 0x4: .red
        case 0x5: .magenta
        case 0x6: .brown
        case 0x7: .lightGray
        case 0x8: .darkGray
        case 0x9: .brightBlue
        case 0xA: .brightGreen
        case 0xB: .brightCyan
        case 0xC: .brightRed
        case 0xD: .brightMagenta
        case 0xE: .yellow
        default: .white
        }
    }
}
