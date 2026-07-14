import Foundation

struct InstructionTraceEntry: Equatable, Sendable {
    let cycle: UInt64
    let cs: UInt16
    let ip: UInt16
    let physicalAddress: UInt32
    let opcode: UInt8

    var text: String {
        String(
            format: "%010llu  %04X:%04X  %05X  %02X",
            cycle,
            cs,
            ip,
            physicalAddress,
            opcode
        )
    }
}

enum MachineDebugger {
    static func exportTrace(_ entries: [InstructionTraceEntry]) -> String {
        let header = "CYCLE       CS:IP      PHYS   OP"
        guard !entries.isEmpty else { return header + "\n" }
        return ([header] + entries.map(\.text)).joined(separator: "\n") + "\n"
    }
}

enum MemoryInspectionError: Error, Equatable, Sendable {
    case negativeByteCount(Int)
    case rangeOutsideAddressSpace(address: UInt32, byteCount: Int)
}

extension MemoryInspectionError: LocalizedError {
    var errorDescription: String? {
        switch self {
        case .negativeByteCount(let byteCount):
            return "Memory inspection byte count cannot be negative (\(byteCount))."
        case .rangeOutsideAddressSpace(let address, let byteCount):
            return String(
                format: "Memory inspection at %05Xh for %d bytes exceeds the 20-bit address space.",
                address,
                byteCount
            )
        }
    }
}
