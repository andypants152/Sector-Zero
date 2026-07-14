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

/// Thread-safe mailbox for raw scan-code bytes. UI threads post; the
/// execution context drains at instruction boundaries, so the PPI and PIC
/// are only ever mutated from the thread running the machine.
private final class HostScanCodeInbox: @unchecked Sendable {
    private let lock = NSLock()
    private var codes: [UInt8] = []

    func post(_ code: UInt8) {
        lock.withLock { codes.append(code) }
    }

    func drain() -> [UInt8] {
        lock.withLock {
            defer { codes.removeAll(keepingCapacity: true) }
            return codes
        }
    }

    func clear() {
        lock.withLock { codes.removeAll() }
    }
}

enum MachineRunStopReason: Equatable, Sendable {
    case instructionLimit
    case breakpoint(UInt32)
    case paused
    case halted
    case waitingForCoprocessor
    case memoryMapViolation(MemoryMapError)
    case fault(CPUFault)
}

struct MachineRunSlice: Equatable, Sendable {
    let executedBoundaries: Int
    let elapsedClocks: UInt64
    let stopReason: MachineRunStopReason
    let trace: [InstructionTraceEntry]
    let snapshot: MachineSnapshot
}

final class Machine {
    private let memory: Memory
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
    private var clockedDevices: [any ClockedDevice] = []
    private let hostScanCodes = HostScanCodeInbox()

    init(memory: Memory = Memory()) {
        self.memory = memory
        self.bus = EmulatorBus(memory: memory)
        self.cpu = CPU8086(bus: bus)
        self.clock = ExecutionClock()
        self.clockedDevices = [bus.intervalTimer, bus.cgaAdapter]
        reset()
    }

    var cycleCount: UInt64 {
        clock.cycleCount
    }

    var currentCodeAddress: UInt32 {
        AddressTranslator.physicalAddress(segment: cpu.cs, offset: cpu.ip)
    }

    var interruptController: ProgrammableInterruptController {
        bus.interruptController
    }

    var dmaController: DirectMemoryAccessController {
        bus.dmaController
    }

    var intervalTimer: ProgrammableIntervalTimer {
        bus.intervalTimer
    }

    var floppyController: FloppyDiskController {
        bus.floppyController
    }

    var diagnosticPort: DiagnosticPort {
        bus.diagnosticPort
    }

    var cgaAdapter: CGATextModeAdapter {
        bus.cgaAdapter
    }

    func reset() {
        bus.resetMemoryMapDiagnostics()
        dmaController.reset()
        interruptController.reset()
        floppyController.reset()
        diagnosticPort.reset()
        cpu.reset()
        clock.reset()
        pendingNMI = false
        pendingINTRVector = nil
        pendingTrap = false
        maskableShadow = 0
        stackSegmentShadow = 0
        suspendedRepeat = nil
        hostScanCodes.clear()
        bus.peripheralInterface.reset()
        for device in clockedDevices {
            device.reset()
        }
    }

    /// Posts one raw XT scan-code byte from any thread. The byte reaches the
    /// PPI at the next instruction boundary of whichever context is running
    /// the machine (see `drainHostInput`).
    func postScanCode(_ code: UInt8) {
        hostScanCodes.post(code)
    }

    /// Feeds posted scan codes to the PPI. Runs automatically at every
    /// step/run boundary; idle callers (a paused workspace) may invoke it
    /// directly since they are the machine's only executor at that moment.
    func drainHostInput() {
        for code in hostScanCodes.drain() {
            bus.peripheralInterface.receiveScanCode(code)
        }
    }

    func loadSystemROM(_ image: Data) throws {
        try bus.loadSystemROM(image)
        reset()
    }

    func clearSystemROM() {
        bus.clearSystemROM()
        reset()
    }

    func mountFloppyDisk(_ image: Data) throws {
        try floppyController.mount(image)
    }

    func ejectFloppyDisk() {
        floppyController.eject()
    }

    func attachClockedDevice(_ device: any ClockedDevice) {
        precondition(!clockedDevices.contains { $0 === device }, "clocked device is already attached")
        clockedDevices.append(device)
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

    func raiseIRQ(_ line: IRQLine) {
        bus.raiseIRQ(line)
    }

    func lowerIRQ(_ line: IRQLine) {
        bus.lowerIRQ(line)
    }

    /// Services one asserted floppy-DMA request and charges the four 8237 bus
    /// clocks to the machine and every clocked device. Direction comes from the
    /// guest-programmed channel-2 mode register.
    @discardableResult
    func serviceDMAChannel2(
        deviceRead: () -> UInt8 = { 0xFF },
        deviceWrite: (UInt8) -> Void = { _ in }
    ) -> DMAServiceResult {
        let result = bus.serviceDMAChannel2(deviceRead: deviceRead, deviceWrite: deviceWrite)
        advanceClock(by: result.clocks)
        return result
    }

    /// Advances one interrupt or instruction boundary. Normal instructions run
    /// fetch → decode → execute; REP may suspend after a completed iteration.
    @discardableResult
    func step() -> Int {
        drainHostInput()
        let start = cycleCount
        stepBoundary()
        return Int(cycleCount - start)
    }

    private func stepBoundary() {
        serviceFloppyDMAIfRequested()
        if resumeRepeatedInstructionIfNeeded() { return }

        if let interruptClocks = acceptPendingBoundaryInterrupt(returnCS: cpu.cs, returnIP: cpu.ip) {
            advanceClock(by: interruptClocks)
            return
        }
        guard cpu.resumeAfterCoprocessorWaitIfReady() else { return }
        guard !cpu.halted else { return }

        var cycles = 0
        let instructionCS = cpu.cs
        let instructionIP = cpu.ip
        let trapWasSet = cpu.flags[.trap]
        let overflowWasSet = cpu.flags[.overflow]
        // Consume segment, repeat, and LOCK prefixes in any order. Each costs
        // 2 clocks; segment/repeat are last-one-wins and LOCK is idempotent.
        var opcode = cpu.fetch()
        var repeatPrefix: RepeatPrefix?
        var lockPrefix = false
        while true {
            if let override = SegmentRegister(overridePrefix: opcode) {
                cpu.setSegmentOverride(override)
            } else if let repeatValue = RepeatPrefix(opcode: opcode) {
                repeatPrefix = repeatValue
            } else if opcode == 0xF0 {
                lockPrefix = true
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
            let result = cpu.executeRepeated(instruction, prefix: repeatPrefix, locked: lockPrefix) {
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
                advanceClock(by: cycles)
                return
            }
        } else {
            cycles += cpu.execute(instruction, locked: lockPrefix)
        }
        cpu.clearSegmentOverride()

        // Emulator diagnostics stop at the offending instruction boundary;
        // they must not be mistaken for interruptible architectural faults.
        if cpu.fault != nil {
            advanceClock(by: cycles)
            return
        }

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
        advanceClock(by: cycles)
    }

    /// Runs a deterministic, instruction-bounded slice and captures one
    /// immutable snapshot at its end. Cancellation is sampled at every
    /// instruction/interrupt boundary, independent of host wall-clock time.
    func runSlice(
        maxInstructions: Int,
        breakpoints: Set<UInt32> = [],
        traceLimit: Int = 0,
        shouldPause: () -> Bool = { false }
    ) -> MachineRunSlice {
        precondition(maxInstructions >= 0, "run-slice bound cannot be negative")
        precondition(traceLimit >= 0, "trace limit cannot be negative")
        let startClocks = cycleCount
        var executedBoundaries = 0
        var stopReason: MachineRunStopReason = .instructionLimit
        var trace: [InstructionTraceEntry] = []
        trace.reserveCapacity(min(maxInstructions, traceLimit))

        while executedBoundaries < maxInstructions {
            // Drain before the halt check so a keystroke can raise IRQ1 and
            // wake a halted CPU inside a running slice.
            drainHostInput()
            if shouldPause() {
                stopReason = .paused
                break
            }
            if let violation = bus.lastMemoryMapError {
                stopReason = .memoryMapViolation(violation)
                break
            }
            if let fault = cpu.fault {
                stopReason = .fault(fault)
                break
            }
            if breakpoints.contains(currentCodeAddress) {
                stopReason = .breakpoint(currentCodeAddress)
                break
            }
            if cpu.halted && !hasWakeableInterrupt && !hasServiceableFloppyDMA {
                stopReason = .halted
                break
            }
            if cpu.waitingForCoprocessor && !bus.coprocessorReady && !hasWakeableInterrupt && !hasServiceableFloppyDMA {
                stopReason = .waitingForCoprocessor
                break
            }
            if traceLimit > 0 {
                if trace.count == traceLimit {
                    trace.removeFirst()
                }
                trace.append(traceEntry())
            }
            step()
            executedBoundaries += 1
        }

        if stopReason == .instructionLimit {
            if let violation = bus.lastMemoryMapError {
                stopReason = .memoryMapViolation(violation)
            } else if let fault = cpu.fault {
                stopReason = .fault(fault)
            } else if cpu.halted && !hasWakeableInterrupt && !hasServiceableFloppyDMA {
                stopReason = .halted
            } else if cpu.waitingForCoprocessor && !bus.coprocessorReady && !hasWakeableInterrupt && !hasServiceableFloppyDMA {
                stopReason = .waitingForCoprocessor
            }
        }

        return MachineRunSlice(
            executedBoundaries: executedBoundaries,
            elapsedClocks: cycleCount - startClocks,
            stopReason: stopReason,
            trace: trace,
            snapshot: snapshot()
        )
    }

    /// Reads a non-wrapping physical-memory range for debugger presentation.
    /// The ordinary bus path is used so ROM, RAM, reserved regions, and mapped
    /// video memory are represented exactly as the CPU observes them.
    func inspectMemory(at address: UInt32, byteCount: Int) throws -> [UInt8] {
        guard byteCount >= 0 else {
            throw MemoryInspectionError.negativeByteCount(byteCount)
        }
        let end = UInt64(address) + UInt64(byteCount)
        guard address < UInt32(Memory.addressableSize),
              end <= UInt64(Memory.addressableSize) else {
            throw MemoryInspectionError.rangeOutsideAddressSpace(
                address: address,
                byteCount: byteCount
            )
        }
        return (0..<byteCount).map { bus.readByte(at: address + UInt32($0)) }
    }

    private func traceEntry() -> InstructionTraceEntry {
        InstructionTraceEntry(
            cycle: cycleCount,
            cs: cpu.cs,
            ip: cpu.ip,
            physicalAddress: currentCodeAddress,
            opcode: bus.readByte(at: currentCodeAddress)
        )
    }

    /// Compatibility wrapper used by instruction tests and simple callers.
    func run(maxSteps: Int) {
        _ = runSlice(maxInstructions: maxSteps)
    }

    private var hasWakeableInterrupt: Bool {
        guard stackSegmentShadow == 0 else { return false }
        if pendingNMI { return true }
        let hasMaskableRequest = pendingINTRVector != nil || interruptController.hasPendingInterrupt
        return maskableShadow == 0 && hasMaskableRequest && cpu.flags[.interruptEnable]
    }

    private var hasServiceableFloppyDMA: Bool {
        floppyController.dmaRequestActive && dmaController.canServiceChannel2
    }

    private func serviceFloppyDMAIfRequested() {
        guard floppyController.dmaRequestActive else { return }
        let result = bus.serviceDMAChannel2(
            deviceRead: floppyController.takeDMAByte,
            deviceWrite: { _ in }
        )
        guard result.transferred else { return }
        advanceClock(by: result.clocks)
        floppyController.completeDMAService(result)
    }

    private func resumeRepeatedInstructionIfNeeded() -> Bool {
        guard let suspendedRepeat else { return false }
        guard cpu.cs == suspendedRepeat.restartCS, cpu.ip == suspendedRepeat.restartIP else {
            return false
        }

        if let interruptClocks = acceptPendingBoundaryInterrupt(returnCS: cpu.cs, returnIP: cpu.ip) {
            advanceClock(by: interruptClocks)
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
        advanceClock(by: cycles)
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
           cpu.flags[.interruptEnable] {
            if let vector = pendingINTRVector {
                pendingINTRVector = nil
                cpu.acceptInterrupt(type: vector, returnCS: returnCS, returnIP: returnIP)
                return 61
            }
            if let vector = interruptController.acknowledge() {
                cpu.acceptInterrupt(type: vector, returnCS: returnCS, returnIP: returnIP)
                return 61
            }
        }
        if pendingTrap {
            pendingTrap = false
            cpu.acceptInterrupt(type: 1, returnCS: returnCS, returnIP: returnIP)
            return 50
        }
        return nil
    }

    func tick() {
        advanceClock(by: 1)
    }

    private func advanceClock(by clocks: Int) {
        guard clocks > 0 else { return }
        clock.advance(by: clocks)
        for device in clockedDevices {
            device.advance(by: clocks)
        }
    }

    /// Captures the machine's observable state as an immutable value for the UI.
    func snapshot() -> MachineSnapshot {
        MachineSnapshot(
            cpu: cpu.dumpState(),
            cycleCount: cycleCount,
            physicalCodeAddress: currentCodeAddress,
            memoryRegions: bus.memoryMapSnapshot,
            loadedSystemROMByteCount: bus.loadedSystemROMByteCount,
            lastMemoryMapError: bus.lastMemoryMapError,
            rejectedROMWriteCount: bus.rejectedROMWriteCount,
            dmaController: dmaController.snapshot,
            floppyController: floppyController.snapshot,
            diagnosticPort: diagnosticPort.snapshot,
            interruptController: interruptController.snapshot,
            intervalTimer: intervalTimer.snapshot,
            peripheralInterface: bus.peripheralInterface.snapshot,
            video: cgaAdapter.snapshot
        )
    }
}
