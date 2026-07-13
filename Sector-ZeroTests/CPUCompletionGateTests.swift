import Testing
@testable import Sector_Zero

private final class CompletionGateSpyBus: Bus {
    var bytes: [UInt32: UInt8] = [:]
    var coprocessorReady = true
    var escapes: [(opcode: UInt8, modRM: UInt8)] = []
    var atomicDepth = 0
    var atomicReads = 0
    var atomicWrites = 0

    func readByte(at address: UInt32) -> UInt8 {
        if atomicDepth > 0 { atomicReads += 1 }
        return bytes[address, default: 0]
    }

    func writeByte(_ value: UInt8, at address: UInt32) {
        if atomicDepth > 0 { atomicWrites += 1 }
        bytes[address] = value
    }

    func readWord(at address: UInt32) -> UInt16 {
        UInt16(readByte(at: address)) | UInt16(readByte(at: address + 1)) << 8
    }

    func writeWord(_ value: UInt16, at address: UInt32) {
        writeByte(UInt8(truncatingIfNeeded: value), at: address)
        writeByte(UInt8(truncatingIfNeeded: value >> 8), at: address + 1)
    }

    func performCoprocessorEscape(opcode: UInt8, modRM: UInt8) {
        escapes.append((opcode, modRM))
    }

    func beginAtomicMemoryAccess() { atomicDepth += 1 }
    func endAtomicMemoryAccess() { atomicDepth -= 1 }
}

/// Milestone 39 — LOCK, WAIT, ESC, and the deliberate opcode-table gate.
struct CPUCompletionGateTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithBytes(_ bytes: [UInt8]) -> Machine {
        let machine = Machine()
        try! machine.bus.loadBytes(bytes, at: resetVector)
        return machine
    }

    @Test("WAIT continues immediately when the coprocessor-ready stub is true")
    func waitReady() {
        let machine = machineWithBytes([0x9B, 0x90])

        machine.step()
        #expect(machine.cpu.ip == 1)
        #expect(machine.cycleCount == 4)
        #expect(!machine.cpu.waitingForCoprocessor)

        machine.step()
        #expect(machine.cpu.ip == 2)
        #expect(machine.cycleCount == 7)
    }

    @Test("WAIT holds fetch until the coprocessor-ready stub changes")
    func waitNotReadyThenReady() {
        let machine = machineWithBytes([0x9B, 0x90])
        machine.bus.coprocessorReady = false

        machine.step()
        machine.step()
        #expect(machine.cpu.ip == 1)
        #expect(machine.cycleCount == 4)
        #expect(machine.cpu.waitingForCoprocessor)

        machine.bus.coprocessorReady = true
        machine.step()
        #expect(machine.cpu.ip == 2)
        #expect(machine.cycleCount == 7)
        #expect(!machine.cpu.waitingForCoprocessor)
    }

    @Test("ESC consumes register, direct, disp8, and disp16 ModR/M lengths")
    func escapeConsumesEveryModRMLength() {
        let decoder = InstructionDecoder()
        let streams: [[UInt8]] = [
            [0xC0],             // mod=11
            [0x06, 0x34, 0x12], // mod=00 direct address
            [0x40, 0x7F],       // mod=01 disp8
            [0x80, 0x34, 0x12], // mod=10 disp16
        ]

        for opcode in UInt8(0xD8)...UInt8(0xDF) {
            for encoded in streams {
                var stream = encoded
                let instruction = decoder.decode(opcode: opcode, registers: RegisterFile()) {
                    stream.removeFirst()
                }
                guard case .coprocessorEscape(let decodedOpcode, let modRM, _, _) = instruction else {
                    Issue.record("ESC did not decode for opcode \(opcode)")
                    continue
                }
                #expect(decodedOpcode == opcode)
                #expect(modRM == encoded[0])
                #expect(stream.isEmpty)
            }
        }
    }

    @Test("ESC delegates to the no-coprocessor bus endpoint")
    func escapeDelegatesToBus() {
        let bus = CompletionGateSpyBus()
        let cpu = CPU8086(bus: bus)

        let clocks = cpu.execute(.coprocessorEscape(
            opcode: 0xDE,
            modRM: 0xC1,
            operand: .register(1),
            eaClocks: 0
        ))

        #expect(clocks == 2)
        #expect(bus.escapes.count == 1)
        #expect(bus.escapes.first?.opcode == 0xDE)
        #expect(bus.escapes.first?.modRM == 0xC1)
    }

    @Test("LOCK wraps a legal memory read-modify-write at the bus boundary")
    func legalLockIsAtomic() {
        let bus = CompletionGateSpyBus()
        let cpu = CPU8086(bus: bus)
        bus.bytes[0x0100] = 0x7F

        let clocks = cpu.execute(
            .incRM8(
                destination: .memory(EffectiveAddress(offset: 0x0100, defaultSegment: .ds)),
                eaClocks: 6
            ),
            locked: true
        )

        #expect(clocks == 21)
        #expect(bus.bytes[0x0100] == 0x80)
        #expect(bus.atomicReads == 1)
        #expect(bus.atomicWrites == 1)
        #expect(bus.atomicDepth == 0)
        #expect(cpu.fault == nil)
    }

    @Test("LOCK composes with segment and repeat prefixes")
    func lockPrefixComposition() {
        // REP ES: LOCK INC byte [0100h]. REP has no repetition meaning here,
        // but all three prefixes are consumed as part of one instruction.
        let machine = machineWithBytes([0xF3, 0x26, 0xF0, 0xFE, 0x06, 0x00, 0x01])
        machine.bus.writeByte(0x10, at: 0x0100)

        machine.step()

        #expect(machine.cpu.ip == 7)
        #expect(machine.bus.readByte(at: 0x0100) == 0x11)
        #expect(machine.bus.atomicMemoryAccessCount == 1)
        #expect(machine.bus.atomicMemoryAccessDepth == 0)
        #expect(machine.cycleCount == 27)
    }

    @Test("LOCK on a register operand stops with an explicit diagnostic")
    func illegalLockFaults() {
        let machine = machineWithBytes([0xF0, 0xFE, 0xC0]) // LOCK INC AL

        machine.step()

        #expect(machine.cpu.ip == 3)
        #expect(machine.cpu.fault == .invalidLockPrefix)
        #expect(machine.cpu.halted)
        #expect(machine.bus.atomicMemoryAccessCount == 0)
        #expect(machine.cycleCount == 2)
    }

    @Test("Every primary opcode has an intentional completion-gate classification")
    func allPrimaryOpcodesAreClassified() {
        var counts: [OpcodeClassification: Int] = [:]
        for opcode in UInt8.min...UInt8.max {
            counts[InstructionDecoder.classification(of: opcode), default: 0] += 1
        }

        #expect(counts.values.reduce(0, +) == 256)
        #expect(counts[.implemented] == 233)
        #expect(counts[.intentionallyReservedOrAliased] == 23)
        #expect(counts[.unsupported, default: 0] == 0)
    }

    @Test("No implemented primary opcode decodes to unknown")
    func supportedOpcodesNeverDecodeUnknown() {
        let decoder = InstructionDecoder()
        let prefixes: Set<UInt8> = [0x26, 0x2E, 0x36, 0x3E, 0xF0, 0xF2, 0xF3]
        for opcode in UInt8.min...UInt8.max
        where InstructionDecoder.classification(of: opcode) == .implemented && !prefixes.contains(opcode) {
            // Zero ModR/M selects a defined operation in every group and leaves
            // ample zero bytes for the longest displacement/immediate form.
            var stream = Array(repeating: UInt8(0), count: 8)
            let instruction = decoder.decode(opcode: opcode, registers: RegisterFile()) {
                stream.removeFirst()
            }
            if case .unknown = instruction {
                Issue.record("Implemented opcode decoded as unknown: \(opcode)")
            }
        }
    }
}
