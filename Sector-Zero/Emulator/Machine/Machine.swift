import Foundation

private struct SuspendedRepeat {
    let instruction: Instruction
    let prefix: RepeatPrefix
    let segmentOverride: SegmentRegister?
    let prefixClocks: Int
    let restartCS: UInt16
    let restartIP: UInt16
    let continuationCS: UInt16
    let continuationIP: UInt16
}

final class Machine {
    let memory: Memory
    let bus: EmulatorBus
    let cpu: CPU8086
    private let clock: ExecutionClock
    private let decoder = InstructionDecoder()
    private var pendingNMI = false
    private var pendingINTRVector: UInt8?
    private var pendingTrap = false
    private var maskableShadow = 0
    private var stackSegmentShadow = 0
    private var suspendedRepeat: SuspendedRepeat?

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
        pendingNMI = false
        pendingINTRVector = nil
        pendingTrap = false
        maskableShadow = 0
        stackSegmentShadow = 0
        suspendedRepeat = nil
    }

    /// Latches a rising-edge request on the 8086 NMI input (fixed vector 2).
    func requestNMI() {
        pendingNMI = true
    }

    func requestNonMaskableInterrupt() {
        requestNMI()
    }

    /// Presents a vector on the maskable INTR input. The request remains
    /// pending until accepted or explicitly withdrawn.
    func requestINTR(vector: UInt8) {
        pendingINTRVector = vector
    }

    func requestMaskableInterrupt(vector: UInt8) {
        requestINTR(vector: vector)
    }

    func clearINTR() {
        pendingINTRVector = nil
    }

    func clearMaskableInterrupt() {
        clearINTR()
    }

    /// Advances one interrupt or instruction boundary. Normal instructions run
    /// fetch → decode → execute; REP may suspend after a completed iteration.
    func step() {
        if resumeRepeatedInstructionIfNeeded() { return }

        if let interruptClocks = acceptPendingBoundaryInterrupt(returnCS: cpu.cs, returnIP: cpu.ip) {
            clock.advance(by: interruptClocks)
            return
        }
        guard !cpu.halted else { return }

        var cycles = 0
        let instructionCS = cpu.cs
        let instructionIP = cpu.ip
        let trapWasSet = cpu.flags[.trap]
        let overflowWasSet = cpu.flags[.overflow]
        // Consume segment and repeat prefixes in any order. Each costs 2 clocks
        // and the last prefix of each kind wins; a repeated string can suspend
        // only at a completed iteration boundary.
        var opcode = cpu.fetch()
        var repeatPrefix: RepeatPrefix?
        while true {
            if let override = SegmentRegister(overridePrefix: opcode) {
                cpu.setSegmentOverride(override)
            } else if let repeatValue = RepeatPrefix(opcode: opcode) {
                repeatPrefix = repeatValue
            } else {
                break
            }
            cycles += 2
            opcode = cpu.fetch()
        }
        let instruction = decoder.decode(opcode: opcode, registers: cpu.registers, nextByte: cpu.fetch)
        let continuationCS = cpu.cs
        let continuationIP = cpu.ip

        if let repeatPrefix {
            var boundaryInterruptClocks = 0
            let result = cpu.executeRepeated(instruction, prefix: repeatPrefix) {
                if let accepted = self.finishRepeatIterationBoundary(
                    trapWasSet: trapWasSet,
                    restartCS: instructionCS,
                    restartIP: instructionIP
                ) {
                    boundaryInterruptClocks = accepted
                    return true
                }
                return false
            }
            cycles += result.cycles + boundaryInterruptClocks
            if result.interrupted {
                suspendedRepeat = SuspendedRepeat(
                    instruction: instruction,
                    prefix: repeatPrefix,
                    segmentOverride: cpu.segmentOverride,
                    prefixClocks: cycles - result.cycles - boundaryInterruptClocks,
                    restartCS: instructionCS,
                    restartIP: instructionIP,
                    continuationCS: continuationCS,
                    continuationIP: continuationIP
                )
                cpu.clearSegmentOverride()
                clock.advance(by: cycles)
                return
            }
        } else {
            cycles += cpu.execute(instruction)
        }
        cpu.clearSegmentOverride()

        let deferOtherInterrupts: Bool = switch instruction {
        case .breakpointInterrupt, .softwareInterrupt: true
        case .interruptOnOverflow: overflowWasSet
        default: false
        }

        cycles += finishInstructionBoundary(
            instruction: instruction,
            trapWasSet: trapWasSet,
            returnCS: cpu.cs,
            returnIP: cpu.ip,
            deferOtherInterrupts: deferOtherInterrupts
        )
        clock.advance(by: cycles)
    }

    /// Steps repeatedly until the CPU halts or `maxSteps` instructions have
    /// executed. The bound keeps runaway programs (and tests) from hanging.
    func run(maxSteps: Int) {
        for _ in 0..<maxSteps {
            if cpu.halted && !hasWakeableInterrupt { return }
            step()
        }
    }

    private var hasWakeableInterrupt: Bool {
        guard stackSegmentShadow == 0 else { return false }
        if pendingNMI { return true }
        return maskableShadow == 0 && pendingINTRVector != nil && cpu.flags[.interruptEnable]
    }

    private func resumeRepeatedInstructionIfNeeded() -> Bool {
        guard let suspendedRepeat else { return false }
        guard cpu.cs == suspendedRepeat.restartCS, cpu.ip == suspendedRepeat.restartIP else {
            return false
        }

        if let interruptClocks = acceptPendingBoundaryInterrupt(returnCS: cpu.cs, returnIP: cpu.ip) {
            clock.advance(by: interruptClocks)
            return true
        }
        guard !cpu.halted else { return true }

        if let segment = suspendedRepeat.segmentOverride {
            cpu.setSegmentOverride(segment)
        }
        let trapWasSet = cpu.flags[.trap]
        var interruptClocks = 0
        let result = cpu.executeRepeated(suspendedRepeat.instruction, prefix: suspendedRepeat.prefix) {
            if let accepted = self.finishRepeatIterationBoundary(
                trapWasSet: trapWasSet,
                restartCS: suspendedRepeat.restartCS,
                restartIP: suspendedRepeat.restartIP
            ) {
                interruptClocks = accepted
                return true
            }
            return false
        }
        var cycles = suspendedRepeat.prefixClocks + result.cycles + interruptClocks
        cpu.clearSegmentOverride()

        if !result.interrupted {
            cpu.setCodeAddress(cs: suspendedRepeat.continuationCS, ip: suspendedRepeat.continuationIP)
            self.suspendedRepeat = nil
            cycles += finishInstructionBoundary(
                instruction: suspendedRepeat.instruction,
                trapWasSet: trapWasSet,
                returnCS: cpu.cs,
                returnIP: cpu.ip
            )
        }
        clock.advance(by: cycles)
        return true
    }

    private func finishRepeatIterationBoundary(
        trapWasSet: Bool,
        restartCS: UInt16,
        restartIP: UInt16
    ) -> Int? {
        consumeExistingShadows()
        if trapWasSet && stackSegmentShadow == 0 {
            pendingTrap = true
        }
        return acceptPendingBoundaryInterrupt(returnCS: restartCS, returnIP: restartIP)
    }

    private func finishInstructionBoundary(
        instruction: Instruction,
        trapWasSet: Bool,
        returnCS: UInt16,
        returnIP: UInt16,
        deferOtherInterrupts: Bool = false
    ) -> Int {
        consumeExistingShadows()
        establishShadow(after: instruction)

        if trapWasSet && stackSegmentShadow == 0 {
            pendingTrap = true
        }

        // Processor-generated divide error outranks every external request and
        // saves the following IP on the original 8086.
        if cpu.takeDivideError() {
            cpu.acceptInterrupt(type: 0, returnCS: returnCS, returnIP: returnIP)
            return 0
        }
        // INT/INT3 have already entered their higher-priority handler. Leave
        // any simultaneous external or single-step request pending for the
        // next boundary rather than nesting it inside the same Machine.step().
        if deferOtherInterrupts { return 0 }
        return acceptPendingBoundaryInterrupt(returnCS: returnCS, returnIP: returnIP) ?? 0
    }

    private func consumeExistingShadows() {
        if maskableShadow > 0 { maskableShadow -= 1 }
        if stackSegmentShadow > 0 { stackSegmentShadow -= 1 }
    }

    private func establishShadow(after instruction: Instruction) {
        switch instruction {
        case .setFlag(.interruptEnable):
            maskableShadow = 1
        case .movRMToSegment(segment: .ss, source: _, eaClocks: _), .popSegment(.ss):
            stackSegmentShadow = 1
        default:
            break
        }
    }

    /// Intel priority: NMI, then maskable INTR, then single-step. Internal
    /// divide errors are handled by the caller before reaching this arbiter.
    private func acceptPendingBoundaryInterrupt(returnCS: UInt16, returnIP: UInt16) -> Int? {
        guard stackSegmentShadow == 0 else { return nil }

        if pendingNMI {
            pendingNMI = false
            cpu.acceptInterrupt(type: 2, returnCS: returnCS, returnIP: returnIP)
            return 50
        }
        if maskableShadow == 0,
           let vector = pendingINTRVector,
           cpu.flags[.interruptEnable] {
            pendingINTRVector = nil
            cpu.acceptInterrupt(type: vector, returnCS: returnCS, returnIP: returnIP)
            return 61
        }
        if pendingTrap {
            pendingTrap = false
            cpu.acceptInterrupt(type: 1, returnCS: returnCS, returnIP: returnIP)
            return 50
        }
        return nil
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
