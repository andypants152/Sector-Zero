import Foundation
import Testing
@testable import Sector_Zero

@MainActor
struct DemoFirmwareTests {
    private var firmwareURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware/demo-keyboard-bios.bin")
    }

    @Test("Demo BIOS boots from the reset vector and prints Hello World")
    func bootsAndPrintsGreeting() throws {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))

        let result = machine.runSlice(maxInstructions: 128)
        #expect(result.stopReason == .halted)
        let characters = result.snapshot.video.cells.prefix(11).map(\.codePoint)
        #expect(characters == Array("Hello World".utf8))
    }

    @Test("Demo BIOS translates keyboard scan codes before displaying them")
    func translatesKeyboardInput() throws {
        let machine = Machine()
        try machine.loadSystemROM(Data(contentsOf: firmwareURL))
        machine.run(maxSteps: 128)

        machine.postScanCode(0x23) // H make code in scan-code set 1.
        let result = machine.runSlice(maxInstructions: 32)
        #expect(result.stopReason == .halted)
        #expect(result.snapshot.video.cells[11].codePoint == UInt8(ascii: "h"))
    }
}
