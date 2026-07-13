import Foundation

enum MemoryRegionKind: String, Equatable, Sendable {
    case ram
    case reserved
    case rom
}

struct MemoryRegionSnapshot: Equatable, Sendable {
    let name: String
    let range: ClosedRange<UInt32>
    let kind: MemoryRegionKind
}

enum MemoryMapError: Error, Equatable, Sendable {
    case invalidRange(ClosedRange<UInt32>)
    case overlappingRegion(ClosedRange<UInt32>)
    case imageTooLarge(size: Int, capacity: Int)
    case imageTargetsReservedSpace(UInt32)
    case writeToReadOnly(UInt32)
}

extension MemoryMapError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .invalidRange(let range):
            return "Memory range \(range) falls outside the 20-bit address space."
        case .overlappingRegion(let range):
            return "Memory range \(range) overlaps an existing region."
        case .imageTooLarge(let size, let capacity):
            return "Firmware image is \(size) bytes; system ROM accepts 1 through \(capacity) bytes."
        case .imageTargetsReservedSpace(let address):
            return String(format: "Image targets reserved address %05Xh.", address)
        case .writeToReadOnly(let address):
            return String(format: "Guest write to read-only address %05Xh was rejected.", address)
        }
    }
}

private final class MappedMemoryRegion {
    let snapshot: MemoryRegionSnapshot
    var romBytes: [UInt8]?

    init(name: String, range: ClosedRange<UInt32>, kind: MemoryRegionKind, romBytes: [UInt8]? = nil) {
        self.snapshot = MemoryRegionSnapshot(name: name, range: range, kind: kind)
        self.romBytes = romBytes
    }
}

protocol Bus: AnyObject {
    func readByte(at address: UInt32) -> UInt8
    func writeByte(_ value: UInt8, at address: UInt32)
    func readWord(at address: UInt32) -> UInt16
    func writeWord(_ value: UInt16, at address: UInt32)
    func readIOByte(at port: UInt16) -> UInt8
    func readIOWord(at port: UInt16) -> UInt16
    func writeIOByte(_ value: UInt8, at port: UInt16)
    func writeIOWord(_ value: UInt16, at port: UInt16)
    var coprocessorReady: Bool { get }
    func performCoprocessorEscape(opcode: UInt8, modRM: UInt8)
    func beginAtomicMemoryAccess()
    func endAtomicMemoryAccess()
}

/// Test and specialist buses that only model memory get deterministic open-bus
/// I/O behavior without needing empty method implementations.
extension Bus {
    func readIOByte(at port: UInt16) -> UInt8 { 0xFF }
    func readIOWord(at port: UInt16) -> UInt16 { 0xFFFF }
    func writeIOByte(_ value: UInt8, at port: UInt16) {}
    func writeIOWord(_ value: UInt16, at port: UInt16) {}
    var coprocessorReady: Bool { true }
    func performCoprocessorEscape(opcode: UInt8, modRM: UInt8) {}
    func beginAtomicMemoryAccess() {}
    func endAtomicMemoryAccess() {}
}

final class EmulatorBus: Bus {
    static let conventionalRAMRange: ClosedRange<UInt32> = 0x00000...0x9FFFF
    static let adapterRange: ClosedRange<UInt32> = 0xA0000...0xEFFFF
    static let systemROMRange: ClosedRange<UInt32> = 0xF0000...0xFFFFF

    private let memory: Memory
    private var memoryRegions: [MappedMemoryRegion] = []
    /// Direct 4 KiB page lookup for the 20-bit address space. PC regions and
    /// adapters are page-aligned in normal operation, making the hot path one
    /// indexed load; the tiny per-page bucket only handles custom edge splits.
    private var memoryRegionPages = Array(
        repeating: [MappedMemoryRegion](),
        count: Memory.addressableSize >> 12
    )
    private var ioDevices: [UInt16: any IOPortDevice] = [:]
    var coprocessorReady = true
    private(set) var atomicMemoryAccessDepth = 0
    private(set) var atomicMemoryAccessCount = 0
    private(set) var lastMemoryMapError: MemoryMapError?
    private(set) var rejectedROMWriteCount = 0
    private(set) var loadedSystemROMByteCount = 0

    init(memory: Memory, installPCMemoryMap: Bool = true) {
        self.memory = memory
        if installPCMemoryMap {
            precondition(memory.size >= Memory.addressableSize, "PC memory map requires 1 MiB of backing storage")
            try! mapRAM(Self.conventionalRAMRange, name: "Conventional RAM")
            try! mapReserved(Self.adapterRange, name: "Adapter Space")
            try! mapROM(Self.systemROMRange, image: [], name: "System ROM")
        }
    }

    func readByte(at address: UInt32) -> UInt8 {
        let address = wrapped(address)
        guard let region = region(containing: address) else { return 0xFF }
        switch region.snapshot.kind {
        case .ram:
            return (try? memory.readByte(at: address)) ?? 0xFF
        case .reserved:
            return 0xFF
        case .rom:
            return region.romBytes?[offset(of: address, in: region)] ?? 0xFF
        }
    }

    func writeByte(_ value: UInt8, at address: UInt32) {
        let address = wrapped(address)
        guard let region = region(containing: address) else { return }
        switch region.snapshot.kind {
        case .ram:
            try? memory.writeByte(value, at: address)
        case .reserved:
            break
        case .rom:
            // Preserve the first unsurfaced violation; the counter records any
            // additional rejected byte cycles until diagnostics are cleared.
            if lastMemoryMapError == nil {
                lastMemoryMapError = .writeToReadOnly(address)
            }
            rejectedROMWriteCount += 1
        }
    }

    func readWord(at address: UInt32) -> UInt16 {
        let lowByte = UInt16(readByte(at: address))
        let highByte = UInt16(readByte(at: address &+ 1))
        return lowByte | (highByte << 8)
    }

    func writeWord(_ value: UInt16, at address: UInt32) {
        // The 8086 performs two independent byte bus cycles. At a protection
        // boundary each cycle keeps its own result: a ROM byte can be rejected
        // while the wrapped or adjacent RAM byte still commits.
        writeByte(UInt8(value & 0x00FF), at: address)
        writeByte(UInt8((value & 0xFF00) >> 8), at: address &+ 1)
    }

    var memoryMapSnapshot: [MemoryRegionSnapshot] {
        memoryRegions.map(\.snapshot)
    }

    func clearMemoryMapError() {
        lastMemoryMapError = nil
    }

    func resetMemoryMapDiagnostics() {
        lastMemoryMapError = nil
        rejectedROMWriteCount = 0
    }

    func mapRAM(_ range: ClosedRange<UInt32>, name: String) throws {
        try addRegion(MappedMemoryRegion(name: name, range: range, kind: .ram))
    }

    func mapReserved(_ range: ClosedRange<UInt32>, name: String) throws {
        try addRegion(MappedMemoryRegion(name: name, range: range, kind: .reserved))
    }

    func mapROM(_ range: ClosedRange<UInt32>, image: [UInt8], name: String) throws {
        let capacity = Int(range.upperBound - range.lowerBound + 1)
        guard image.count <= capacity else {
            throw MemoryMapError.imageTooLarge(size: image.count, capacity: capacity)
        }
        var bytes = Array(repeating: UInt8(0xFF), count: capacity)
        bytes.replaceSubrange((capacity - image.count)..<capacity, with: image)
        try addRegion(MappedMemoryRegion(name: name, range: range, kind: .rom, romBytes: bytes))
    }

    /// Replaces the system ROM contents, top-aligning common 8/16/32/64 KiB
    /// firmware images so their final 16 bytes cover the 8086 reset vector.
    func loadSystemROM(_ image: Data) throws {
        guard let region = memoryRegions.first(where: { $0.snapshot.range == Self.systemROMRange && $0.snapshot.kind == .rom }) else {
            preconditionFailure("system ROM region is not mapped")
        }
        let capacity = Int(Self.systemROMRange.upperBound - Self.systemROMRange.lowerBound + 1)
        guard !image.isEmpty, image.count <= capacity else {
            throw MemoryMapError.imageTooLarge(size: image.count, capacity: capacity)
        }
        var bytes = Array(repeating: UInt8(0xFF), count: capacity)
        bytes.replaceSubrange((capacity - image.count)..<capacity, with: image)
        region.romBytes = bytes
        loadedSystemROMByteCount = image.count
        lastMemoryMapError = nil
    }

    func clearSystemROM() {
        guard let region = memoryRegions.first(where: { $0.snapshot.range == Self.systemROMRange && $0.snapshot.kind == .rom }) else {
            preconditionFailure("system ROM region is not mapped")
        }
        region.romBytes = Array(repeating: 0xFF, count: Int(Self.systemROMRange.count))
        loadedSystemROMByteCount = 0
        lastMemoryMapError = nil
    }

    /// Host-side image loading bypasses guest ROM write protection while still
    /// respecting mapped/reserved regions. It is used for deterministic test
    /// programs and machine configuration, never by CPU execution.
    func loadBytes(_ bytes: [UInt8], at startAddress: UInt32) throws {
        for (index, byte) in bytes.enumerated() {
            let address = wrapped(startAddress &+ UInt32(index))
            guard let region = region(containing: address) else {
                throw MemoryMapError.imageTargetsReservedSpace(address)
            }
            switch region.snapshot.kind {
            case .ram:
                try? memory.writeByte(byte, at: address)
            case .reserved:
                throw MemoryMapError.imageTargetsReservedSpace(address)
            case .rom:
                region.romBytes?[offset(of: address, in: region)] = byte
            }
        }
    }

    /// Maps an inclusive port range to one device. Overlapping mappings are a
    /// configuration error rather than silently changing machine topology.
    func mapPortDevice(_ device: any IOPortDevice, to ports: ClosedRange<UInt16>) {
        precondition(ports.allSatisfy { ioDevices[$0] == nil }, "I/O port range overlaps an existing device")
        for port in ports {
            ioDevices[port] = device
        }
    }

    func readIOByte(at port: UInt16) -> UInt8 {
        ioDevices[port]?.readByte(from: port) ?? 0xFF
    }

    func readIOWord(at port: UInt16) -> UInt16 {
        ioDevices[port]?.readWord(from: port) ?? 0xFFFF
    }

    func writeIOByte(_ value: UInt8, at port: UInt16) {
        ioDevices[port]?.writeByte(value, to: port)
    }

    func writeIOWord(_ value: UInt16, at port: UInt16) {
        ioDevices[port]?.writeWord(value, to: port)
    }

    /// The base machine has no 8087. ESC therefore reaches a deterministic
    /// no-coprocessor endpoint after the decoder has consumed its full operand.
    func performCoprocessorEscape(opcode: UInt8, modRM: UInt8) {}

    func beginAtomicMemoryAccess() {
        atomicMemoryAccessDepth += 1
        atomicMemoryAccessCount += 1
    }

    func endAtomicMemoryAccess() {
        precondition(atomicMemoryAccessDepth > 0, "unbalanced atomic memory access")
        atomicMemoryAccessDepth -= 1
    }

    private func addRegion(_ region: MappedMemoryRegion) throws {
        let range = region.snapshot.range
        guard range.lowerBound <= range.upperBound,
              range.upperBound <= AddressTranslator.physicalAddressMask else {
            throw MemoryMapError.invalidRange(range)
        }
        guard !memoryRegions.contains(where: { $0.snapshot.range.overlaps(range) }) else {
            throw MemoryMapError.overlappingRegion(range)
        }
        memoryRegions.append(region)
        memoryRegions.sort { $0.snapshot.range.lowerBound < $1.snapshot.range.lowerBound }
        let firstPage = Int(range.lowerBound >> 12)
        let lastPage = Int(range.upperBound >> 12)
        for page in firstPage...lastPage {
            memoryRegionPages[page].append(region)
        }
    }

    private func region(containing address: UInt32) -> MappedMemoryRegion? {
        let candidates = memoryRegionPages[Int(address >> 12)]
        if candidates.count == 1 {
            let candidate = candidates[0]
            return candidate.snapshot.range.contains(address) ? candidate : nil
        }
        for candidate in candidates where candidate.snapshot.range.contains(address) {
            return candidate
        }
        return nil
    }

    private func wrapped(_ address: UInt32) -> UInt32 {
        address & AddressTranslator.physicalAddressMask
    }

    private func offset(of address: UInt32, in region: MappedMemoryRegion) -> Int {
        Int(address - region.snapshot.range.lowerBound)
    }
}
