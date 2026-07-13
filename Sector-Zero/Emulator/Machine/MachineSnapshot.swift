import Foundation

/// An immutable, value-type view of the machine's observable state at one instant.
///
/// The UI renders from this snapshot rather than reaching into the live `Machine`,
/// keeping the emulator core free of any UI or observation concerns.
struct MachineSnapshot: Equatable, Sendable {
    let cpu: CPUStateSnapshot
    let cycleCount: UInt64
    let physicalCodeAddress: UInt32
    let memoryRegions: [MemoryRegionSnapshot]
    let loadedSystemROMByteCount: Int
    let lastMemoryMapError: MemoryMapError?
    let rejectedROMWriteCount: Int
}
