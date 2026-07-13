import Foundation

struct DiagnosticPortSnapshot: Equatable, Sendable {
    let lastCode: UInt8?
    let codes: [UInt8]
}

/// Test-only firmware progress port. Guest writes are observable in snapshots
/// and tests, but never alter CPU, memory, or device behavior.
final class DiagnosticPort: IOPortDevice {
    static let port: UInt16 = 0xE9
    private static let maximumRecordedCodes = 256

    private var codes: [UInt8] = []

    var snapshot: DiagnosticPortSnapshot {
        DiagnosticPortSnapshot(lastCode: codes.last, codes: codes)
    }

    func reset() {
        codes.removeAll(keepingCapacity: true)
    }

    func readByte(from port: UInt16) -> UInt8 {
        codes.last ?? 0
    }

    func writeByte(_ value: UInt8, to port: UInt16) {
        if codes.count == Self.maximumRecordedCodes {
            codes.removeFirst()
        }
        codes.append(value)
    }
}
