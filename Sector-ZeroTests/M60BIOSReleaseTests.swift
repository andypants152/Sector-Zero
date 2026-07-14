import Foundation
import Testing
@testable import Sector_Zero

@MainActor
struct M60BIOSReleaseTests {
    private var firmwareURL: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
            .appendingPathComponent("Project/Firmware/sector-zero-bios-1.0.bin")
    }

    @Test("System BIOS 1.0 has stable identity and a valid 64 KiB checksum")
    func releaseIdentity() throws {
        let bytes = [UInt8](try Data(contentsOf: firmwareURL))
        #expect(bytes.count == 65_536)
        #expect(bytes.reduce(UInt8(0)) { $0 &+ $1 } == 0)
        #expect(bytes[0xFFF0] == 0xEA)
        #expect(String(decoding: bytes[0xFFF5...0xFFFC], as: UTF8.self) == "07/14/26")
        #expect(bytes[0xFFFE] == 0xFF)
        #expect(String(decoding: bytes, as: UTF8.self).contains("Sector Zero System BIOS 1.0"))
    }

    @Test("The canonical release ROM is the app's bundled default")
    func bundledDefault() throws {
        let bundleURL = try #require(Bundle.main.url(
            forResource: "sector-zero-bios-1.0",
            withExtension: "bin"
        ))
        #expect(try Data(contentsOf: bundleURL) == Data(contentsOf: firmwareURL))
    }
}
