import Foundation

final class Machine {
    let memory: Memory
    let bus: Bus
    let cpu: CPU8086
    private let clock: ExecutionClock
    private let decoder = InstructionDecoder()

    init(memory: Memory = Memory()) {
        self.memory = memory
        self.bus = EmulatorBus(memory: memory)
        self.cpu = CPU8086(bus: bus)
        self.clock = ExecutionClock()
        reset()
    }

    var cycleCount: UInt64 {
        clock.cycleCount
    }

    var currentCodeAddress: UInt32 {
        AddressTranslator.physicalAddress(segment: cpu.cs, offset: cpu.ip)
    }

    func reset() {
        cpu.reset()
        clock.reset()
    }

    /// Advances the machine by a single instruction: fetch → decode → execute,
    /// then charges the instruction's clock cost to the execution clock.
    func step() {
        let opcode = cpu.fetch()
        let instruction = decoder.decode(opcode: opcode, nextByte: cpu.fetch)
        let cycles = cpu.execute(instruction)
        clock.advance(by: cycles)
    }

    func tick() {
        // Individual clock cycles will be driven from within `step()` once
        // instruction timing lands.
        clock.tick()
    }

    /// Captures the machine's observable state as an immutable value for the UI.
    func snapshot() -> MachineSnapshot {
        MachineSnapshot(
            cpu: cpu.dumpState(),
            cycleCount: cycleCount,
            physicalCodeAddress: currentCodeAddress
        )
    }
}
