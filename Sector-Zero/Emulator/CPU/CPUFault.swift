import Foundation

/// Legacy snapshot surface retained for compatibility. CPU-generated divide
/// errors now route through the real-mode interrupt table.
enum CPUFault: Equatable, Sendable {
    case divideError
}
