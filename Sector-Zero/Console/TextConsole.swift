import Foundation

final class TextConsole {
    static let columns = 80
    static let rows = 25

    let columns: Int
    let rows: Int
    let font: ConsoleFont

    private(set) var cursorColumn: Int = 0
    private(set) var cursorRow: Int = 0

    var foreground: ConsoleColor
    var background: ConsoleColor
    var isCursorEnabled = true
    var cursorBlinkInterval: TimeInterval = 0.5

    private var cells: [ConsoleCell]

    init(
        columns: Int = TextConsole.columns,
        rows: Int = TextConsole.rows,
        font: ConsoleFont = CP437Font(),
        foreground: ConsoleColor = .lightGray,
        background: ConsoleColor = .black
    ) {
        self.columns = columns
        self.rows = rows
        self.font = font
        self.foreground = foreground
        self.background = background
        self.cells = Array(
            repeating: ConsoleCell(foreground: foreground, background: background),
            count: columns * rows
        )
    }

    var pixelWidth: Int {
        columns * font.cellWidth
    }

    var pixelHeight: Int {
        rows * font.cellHeight
    }

    func clear() {
        cells = Array(repeating: blankCell(), count: columns * rows)
        cursorColumn = 0
        cursorRow = 0
    }

    func setCursor(column: Int, row: Int) {
        cursorColumn = min(max(column, 0), columns - 1)
        cursorRow = min(max(row, 0), rows - 1)
    }

    func write(_ string: String) {
        for scalar in string.unicodeScalars {
            switch scalar {
            case "\n":
                newline()
            case "\r":
                carriageReturn()
            default:
                guard scalar.value <= UInt8.max else {
                    writeCharacter(UInt8(ascii: "?"))
                    continue
                }

                writeCharacter(UInt8(scalar.value))
            }
        }
    }

    func writeCharacter(_ codePoint: UInt8, blink: Bool = false) {
        cells[index(column: cursorColumn, row: cursorRow)] = ConsoleCell(
            codePoint: codePoint,
            foreground: foreground,
            background: background,
            blink: blink
        )
        advanceCursor()
    }

    func newline() {
        cursorColumn = 0
        cursorRow += 1
        scrollIfNeeded()
    }

    func carriageReturn() {
        cursorColumn = 0
    }

    func render(into frameBuffer: FrameBuffer, time: TimeInterval) {
        for row in 0..<rows {
            for column in 0..<columns {
                renderCell(column: column, row: row, into: frameBuffer)
            }
        }

        renderCursor(into: frameBuffer, time: time)
    }

    private func renderCell(column: Int, row: Int, into frameBuffer: FrameBuffer) {
        let cell = cells[index(column: column, row: row)]
        let originX = column * font.cellWidth
        let originY = row * font.cellHeight

        frameBuffer.fillRect(
            x: originX,
            y: originY,
            width: font.cellWidth,
            height: font.cellHeight,
            color: cell.background.frameBufferColor
        )

        for glyphRow in 0..<font.cellHeight {
            let bits = font.rowBits(for: cell.codePoint, row: glyphRow)
            for glyphColumn in 0..<font.cellWidth {
                let mask = UInt8(0x80 >> glyphColumn)
                guard bits & mask != 0 else {
                    continue
                }

                frameBuffer.setPixel(
                    x: originX + glyphColumn,
                    y: originY + glyphRow,
                    color: cell.foreground.frameBufferColor
                )
            }
        }
    }

    private func renderCursor(into frameBuffer: FrameBuffer, time: TimeInterval) {
        guard isCursorEnabled, isCursorVisible(time: time) else {
            return
        }

        let originX = cursorColumn * font.cellWidth
        let originY = cursorRow * font.cellHeight
        frameBuffer.fillRect(
            x: originX,
            y: originY,
            width: font.cellWidth,
            height: font.cellHeight,
            color: foreground.frameBufferColor
        )
    }

    private func isCursorVisible(time: TimeInterval) -> Bool {
        guard cursorBlinkInterval > 0 else {
            return true
        }

        let phase = Int((time / cursorBlinkInterval).rounded(.down))
        return phase.isMultiple(of: 2)
    }

    private func advanceCursor() {
        cursorColumn += 1
        if cursorColumn >= columns {
            newline()
        }
    }

    private func scrollIfNeeded() {
        guard cursorRow >= rows else {
            return
        }

        cells.removeFirst(columns)
        cells.append(contentsOf: Array(repeating: blankCell(), count: columns))
        cursorRow = rows - 1
    }

    private func blankCell() -> ConsoleCell {
        ConsoleCell(foreground: foreground, background: background)
    }

    private func index(column: Int, row: Int) -> Int {
        row * columns + column
    }
}
