import Foundation

struct ConsoleColor: Equatable, Sendable {
    let frameBufferColor: FrameBufferColor

    static let black = ConsoleColor(frameBufferColor: .black)
    static let blue = ConsoleColor(frameBufferColor: FrameBufferColor(red: 0, green: 0, blue: 170, alpha: 255))
    static let green = ConsoleColor(frameBufferColor: FrameBufferColor(red: 0, green: 170, blue: 0, alpha: 255))
    static let cyan = ConsoleColor(frameBufferColor: FrameBufferColor(red: 0, green: 170, blue: 170, alpha: 255))
    static let red = ConsoleColor(frameBufferColor: FrameBufferColor(red: 170, green: 0, blue: 0, alpha: 255))
    static let magenta = ConsoleColor(frameBufferColor: FrameBufferColor(red: 170, green: 0, blue: 170, alpha: 255))
    static let brown = ConsoleColor(frameBufferColor: FrameBufferColor(red: 170, green: 85, blue: 0, alpha: 255))
    static let lightGray = ConsoleColor(frameBufferColor: FrameBufferColor(red: 170, green: 170, blue: 170, alpha: 255))
    static let darkGray = ConsoleColor(frameBufferColor: FrameBufferColor(red: 85, green: 85, blue: 85, alpha: 255))
    static let brightBlue = ConsoleColor(frameBufferColor: FrameBufferColor(red: 85, green: 85, blue: 255, alpha: 255))
    static let brightGreen = ConsoleColor(frameBufferColor: FrameBufferColor(red: 85, green: 255, blue: 85, alpha: 255))
    static let brightCyan = ConsoleColor(frameBufferColor: FrameBufferColor(red: 85, green: 255, blue: 255, alpha: 255))
    static let brightRed = ConsoleColor(frameBufferColor: FrameBufferColor(red: 255, green: 85, blue: 85, alpha: 255))
    static let brightMagenta = ConsoleColor(frameBufferColor: FrameBufferColor(red: 255, green: 85, blue: 255, alpha: 255))
    static let yellow = ConsoleColor(frameBufferColor: FrameBufferColor(red: 255, green: 255, blue: 85, alpha: 255))
    static let white = ConsoleColor(frameBufferColor: FrameBufferColor(red: 255, green: 255, blue: 255, alpha: 255))
}
