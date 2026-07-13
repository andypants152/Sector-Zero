import Foundation

final class ExecutionClock {
    private(set) var cycleCount: UInt64 = 0

    func reset() {
        cycleCount = 0
    }

    func tick() {
        cycleCount += 1
    }
}
