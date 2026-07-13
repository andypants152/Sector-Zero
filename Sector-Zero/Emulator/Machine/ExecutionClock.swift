import Foundation

final class ExecutionClock {
    private(set) var cycleCount: UInt64 = 0

    func reset() {
        cycleCount = 0
    }

    func tick() {
        cycleCount += 1
    }

    /// Charges the cost of one executed instruction to the running cycle count.
    func advance(by cycles: Int) {
        cycleCount += UInt64(cycles)
    }
}
