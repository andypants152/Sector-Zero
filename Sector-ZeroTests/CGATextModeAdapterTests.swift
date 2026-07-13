import Testing
@testable import Sector_Zero

/// Milestone 44 — CGA 80×25 text memory, registers, snapshots, and rendering.
struct CGATextModeAdapterTests {
    private func setCRTC(_ register: UInt8, to value: UInt8, bus: EmulatorBus) {
        bus.writeIOByte(register, at: 0x3D4)
        bus.writeIOByte(value, at: 0x3D5)
    }

    private func enableText(blink: Bool = false, bus: EmulatorBus) {
        bus.writeIOByte(blink ? 0x29 : 0x09, at: 0x3D8)
    }

    private func writeCell(
        _ cell: Int,
        character: UInt8,
        attribute: UInt8,
        bus: EmulatorBus
    ) {
        let address = UInt32(0xB8000 + cell * 2)
        bus.writeByte(character, at: address)
        bus.writeByte(attribute, at: address + 1)
    }

    @Test("CGA VRAM is a writable 16 KiB device window inside adapter space")
    func videoMemoryMapping() {
        let machine = Machine()
        machine.bus.writeByte(0x12, at: 0xB8000)
        machine.bus.writeByte(0x34, at: 0xBBFFF)
        machine.bus.writeByte(0x56, at: 0xB7FFF)
        machine.bus.writeByte(0x78, at: 0xBC000)

        #expect(machine.bus.readByte(at: 0xB8000) == 0x12)
        #expect(machine.bus.readByte(at: 0xBBFFF) == 0x34)
        #expect(machine.bus.readByte(at: 0xB7FFF) == 0xFF)
        #expect(machine.bus.readByte(at: 0xBC000) == 0xFF)
    }

    @Test("Character and attribute bytes decode through the CGA palette and blink mode")
    func characterAndAttributeDecoding() {
        let machine = Machine()
        enableText(blink: true, bus: machine.bus)
        writeCell(0, character: UInt8(ascii: "A"), attribute: 0x9E, bus: machine.bus)

        let blinking = machine.snapshot().video.cells[0]
        #expect(blinking.codePoint == UInt8(ascii: "A"))
        #expect(blinking.foreground == .yellow)
        #expect(blinking.background == .blue)
        #expect(blinking.blink)

        enableText(blink: false, bus: machine.bus)
        let brightBackground = machine.snapshot().video.cells[0]
        #expect(brightBackground.background == .brightBlue)
        #expect(!brightBackground.blink)
    }

    @Test("Text mode starts with deterministic blank cells")
    func blankResetState() {
        let machine = Machine()
        enableText(bus: machine.bus)

        let firstCell = machine.snapshot().video.cells[0]
        let lastCell = machine.snapshot().video.cells[1_999]
        #expect(firstCell.codePoint == UInt8(ascii: " "))
        #expect(firstCell.foreground == .lightGray)
        #expect(firstCell.background == .black)
        #expect(lastCell == firstCell)

        machine.bus.writeByte(UInt8(ascii: "X"), at: 0xB8000)
        machine.reset()
        machine.bus.writeIOByte(0x09, at: 0x3D8)
        #expect(machine.snapshot().video.cells[0].codePoint == UInt8(ascii: " "))
    }

    @Test("CRTC start and cursor registers are cell addresses relative to the visible page")
    func crtcCursorRegisters() {
        let machine = Machine()
        enableText(bus: machine.bus)
        setCRTC(0x0C, to: 0x00, bus: machine.bus)
        setCRTC(0x0D, to: 80, bus: machine.bus)
        setCRTC(0x0E, to: 0x00, bus: machine.bus)
        setCRTC(0x0F, to: 82, bus: machine.bus)
        setCRTC(0x0A, to: 13, bus: machine.bus)
        setCRTC(0x0B, to: 15, bus: machine.bus)

        let snapshot = machine.snapshot().video
        #expect(snapshot.displayStartAddress == 80)
        #expect(snapshot.cursorAddress == 82)
        #expect(snapshot.cursorPosition == 2)
        #expect(snapshot.cursorStartLine == 13)
        #expect(snapshot.cursorEndLine == 15)
        #expect(machine.bus.readIOByte(at: 0x3D5) == 15)

        setCRTC(0x0A, to: 0x20, bus: machine.bus)
        #expect(machine.snapshot().video.cursorPosition == nil)
    }

    @Test("Changing the display start address represents a scrolling VRAM layout")
    func scrollingLayout() {
        let machine = Machine()
        enableText(bus: machine.bus)
        writeCell(0, character: UInt8(ascii: "A"), attribute: 0x07, bus: machine.bus)
        writeCell(80, character: UInt8(ascii: "B"), attribute: 0x1F, bus: machine.bus)
        setCRTC(0x0D, to: 80, bus: machine.bus)

        let snapshot = machine.snapshot().video
        #expect(snapshot.cells[0].codePoint == UInt8(ascii: "B"))
        #expect(snapshot.cells[0].foreground == .white)
        #expect(snapshot.cells[0].background == .blue)
    }

    @Test("Disabled, 40-column, and graphics modes do not expose text cells")
    func unsupportedModes() {
        let machine = Machine()
        writeCell(0, character: UInt8(ascii: "X"), attribute: 0x0F, bus: machine.bus)

        #expect(machine.snapshot().video.displayMode == .disabled)
        #expect(machine.snapshot().video.cells[0].foreground == .black)
        machine.bus.writeIOByte(0x08, at: 0x3D8)
        #expect(machine.snapshot().video.displayMode == .unsupported)
        machine.bus.writeIOByte(0x0B, at: 0x3D8)
        #expect(machine.snapshot().video.displayMode == .unsupported)

        enableText(bus: machine.bus)
        #expect(machine.snapshot().video.cells[0].codePoint == UInt8(ascii: "X"))
    }

    @Test("Video snapshots retain old VRAM and register values after later writes")
    func snapshotImmutability() {
        let machine = Machine()
        enableText(bus: machine.bus)
        writeCell(0, character: UInt8(ascii: "A"), attribute: 0x07, bus: machine.bus)
        let before = machine.snapshot().video

        writeCell(0, character: UInt8(ascii: "Z"), attribute: 0x4F, bus: machine.bus)
        machine.bus.writeIOByte(0x00, at: 0x3D8)

        #expect(before.displayMode == .text80x25)
        #expect(before.cells[0].codePoint == UInt8(ascii: "A"))
        #expect(machine.snapshot().video.cells[0].codePoint == 0)
    }

    @Test("Status port exposes deterministic display and vertical-retrace phases")
    func statusPort() {
        let machine = Machine()
        #expect(machine.bus.readIOByte(at: 0x3DA) & 0x01 == 0x01)
        machine.cgaAdapter.advance(by: 75_000)
        #expect(machine.bus.readIOByte(at: 0x3DA) & 0x08 == 0x08)
        #expect(machine.snapshot().video.status & 0x08 == 0x08)
    }

    @Test("An 80x25 snapshot renders a 640x400 CGA-colored fixture")
    func visualFixture() {
        let machine = Machine()
        enableText(bus: machine.bus)
        setCRTC(0x0A, to: 0x20, bus: machine.bus) // Keep fixture independent of cursor blink.
        writeCell(0, character: UInt8(ascii: "A"), attribute: 0x1E, bus: machine.bus)
        writeCell(1_999, character: UInt8(ascii: "Z"), attribute: 0x4F, bus: machine.bus)

        let console = TextConsole()
        console.apply(video: machine.snapshot().video)
        let frame = FrameBuffer(width: console.pixelWidth, height: console.pixelHeight)
        console.render(into: frame, time: 0)

        #expect(frame.width == 640)
        #expect(frame.height == 400)
        #expect(pixel(in: frame, x: 0, y: 0) == ConsoleColor.blue.frameBufferColor)
        #expect(pixel(in: frame, x: 3, y: 1) == ConsoleColor.yellow.frameBufferColor)
        #expect(pixel(in: frame, x: 639, y: 399) == ConsoleColor.red.frameBufferColor)
    }

    private func pixel(in frame: FrameBuffer, x: Int, y: Int) -> FrameBufferColor {
        let index = (y * frame.width + x) * 4
        return FrameBufferColor(
            red: frame.pixels[index],
            green: frame.pixels[index + 1],
            blue: frame.pixels[index + 2],
            alpha: frame.pixels[index + 3]
        )
    }
}
