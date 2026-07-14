import Foundation

enum DiagnosticEventStatus: UInt8, Equatable, Sendable {
    case started = 0x00
    case passed = 0x01
    case failed = 0x02
    case skipped = 0x03
}

struct DiagnosticEvent: Equatable, Sendable {
    static let signature: UInt8 = 0x53
    static let suiteCompletionCase: UInt8 = 0xFF

    let suite: UInt8
    let testCase: UInt8
    let status: DiagnosticEventStatus
}

enum DiagnosticEventDecoder {
    /// Decodes the self-synchronizing four-byte firmware test protocol while
    /// ignoring legacy single-byte POST codes and incomplete trailing events.
    static func decode(_ bytes: [UInt8]) -> [DiagnosticEvent] {
        var events: [DiagnosticEvent] = []
        var index = 0
        while index + 3 < bytes.count {
            guard bytes[index] == DiagnosticEvent.signature,
                  let status = DiagnosticEventStatus(rawValue: bytes[index + 3]) else {
                index += 1
                continue
            }
            events.append(DiagnosticEvent(
                suite: bytes[index + 1],
                testCase: bytes[index + 2],
                status: status
            ))
            index += 4
        }
        return events
    }
}

struct DiagnosticPortSnapshot: Equatable, Sendable {
    let lastCode: UInt8?
    let codes: [UInt8]

    var events: [DiagnosticEvent] {
        DiagnosticEventDecoder.decode(codes)
    }
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
