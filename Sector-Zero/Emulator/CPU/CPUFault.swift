import Foundation

/// Emulator diagnostics that are not architectural 8086 exceptions. Divide
/// errors route through vector 0; unsupported implementation gaps stop the
/// emulator explicitly instead of silently behaving like NOP.
enum CPUFault: Equatable, Sendable {
    case divideError
    case unsupportedOpcode(UInt8)
    case invalidLockPrefix
}
