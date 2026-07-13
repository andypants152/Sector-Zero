import Foundation

struct ConsoleCell: Equatable, Sendable {
    var codePoint: UInt8
    var foreground: ConsoleColor
    var background: ConsoleColor
    var blink: Bool

    init(
        codePoint: UInt8 = 32,
        foreground: ConsoleColor = .lightGray,
        background: ConsoleColor = .black,
        blink: Bool = false
    ) {
        self.codePoint = codePoint
        self.foreground = foreground
        self.background = background
        self.blink = blink
    }
}
