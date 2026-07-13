import Testing
@testable import Sector_Zero

/// Milestone 2 — instruction fetch.
///
/// A fetch reads one opcode byte from the code stream at CS:IP through the bus and
/// advances IP past it. Nothing is decoded or executed yet. At reset CS:IP is
/// FFFF:0000, which the translator maps to physical FFFF0h, so tests seed the
/// opcode there.
struct InstructionFetchTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            machine.bus.writeByte(opcode, at: resetVector + UInt32(offset))
        }
        return machine
    }

    @Test("No opcode is recorded before the first fetch")
    func opcodeNilBeforeFetch() {
        let machine = Machine()
        #expect(machine.cpu.lastFetchedOpcode == nil)
        #expect(machine.snapshot().cpu.lastFetchedOpcode == nil)
        #expect(machine.snapshot().cpu.lastFetchedOpcodeText == "--")
    }

    @Test("Fetch reads the opcode at the reset vector CS:IP")
    func fetchReadsOpcodeAtResetVector() {
        let machine = machineWithOpcodes([0x90])
        let opcode = machine.cpu.fetch()
        #expect(opcode == 0x90)
        #expect(machine.cpu.lastFetchedOpcode == 0x90)
    }

    @Test("Fetch advances IP by one each time")
    func fetchAdvancesIP() {
        let machine = Machine()
        #expect(machine.cpu.ip == 0x0000)
        machine.cpu.fetch()
        #expect(machine.cpu.ip == 0x0001)
        machine.cpu.fetch()
        #expect(machine.cpu.ip == 0x0002)
    }

    @Test("Successive fetches walk consecutive bytes of the code stream")
    func fetchReadsConsecutiveBytes() {
        let machine = machineWithOpcodes([0x11, 0x22, 0x33])
        #expect(machine.cpu.fetch() == 0x11)
        #expect(machine.cpu.fetch() == 0x22)
        #expect(machine.cpu.fetch() == 0x33)
        #expect(machine.cpu.ip == 0x0003)
    }

    @Test("IP wraps within the segment after offset FFFFh")
    func ipWrapsAtSegmentEnd() {
        let machine = Machine()
        for _ in 0..<0x1_0000 {
            machine.cpu.fetch()
        }
        #expect(machine.cpu.ip == 0x0000)
    }

    @Test("Machine.step() performs exactly one fetch")
    func stepPerformsSingleFetch() {
        let machine = machineWithOpcodes([0xAB])
        machine.step()
        let snapshot = machine.snapshot()
        #expect(snapshot.cpu.lastFetchedOpcode == 0xAB)
        #expect(snapshot.cpu.ip == 0x0001)
    }

    @Test("Reset clears the last fetched opcode and rewinds IP")
    func resetClearsFetchState() {
        let machine = machineWithOpcodes([0x90])
        machine.step()
        #expect(machine.cpu.lastFetchedOpcode == 0x90)

        machine.reset()
        #expect(machine.cpu.lastFetchedOpcode == nil)
        #expect(machine.cpu.ip == 0x0000)
        #expect(machine.cpu.cs == 0xFFFF)
    }

    @Test("Snapshot reflects the advanced code pointer after a fetch")
    func snapshotReflectsAdvancedPointer() {
        let machine = Machine()
        machine.step()
        let snapshot = machine.snapshot()
        // CS stays FFFF, IP advanced to 0001 → physical FFFF1h.
        #expect(snapshot.cpu.ip == 0x0001)
        #expect(snapshot.physicalCodeAddress == 0xFFFF1)
    }

    @Test("Opcode text is formatted as two hex digits")
    func opcodeTextFormatting() {
        let machine = machineWithOpcodes([0x0A])
        machine.step()
        #expect(machine.snapshot().cpu.lastFetchedOpcodeText == "0A")
    }
}
