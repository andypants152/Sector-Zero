import Foundation

final class ConsoleBootScene {
    let console: TextConsole

    init(console: TextConsole = TextConsole(foreground: .brightGreen, background: .black)) {
        self.console = console
        composeBootScreen()
    }

    func render(into frameBuffer: FrameBuffer, time: TimeInterval) {
        console.render(into: frameBuffer, time: time)
    }

    private func composeBootScreen() {
        console.clear()
        console.write("Sector Zero\n")
        console.write("Version 0.1\n")
        console.write("\n")
        console.write("Initializing video...\n")
        console.write("Loading virtual hardware...\n")
        console.write("Ready.\n")
        console.write("\n")
        console.write("C:>")
    }
}
