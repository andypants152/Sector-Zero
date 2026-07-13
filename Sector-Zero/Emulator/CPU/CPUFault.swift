import Foundation

/// Temporary observable halt reasons used until M35 can route CPU-generated
/// faults through the real-mode interrupt mechanism.
enum CPUFault: Equatable, Sendable {
    case divideError
}
