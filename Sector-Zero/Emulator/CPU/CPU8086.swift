import Foundation

final class CPU8086 {
    // The CPU only talks to memory and devices through this bus boundary.
    private let bus: Bus

    /// General-purpose register storage, addressable as words or byte halves.
    private(set) var registers = RegisterFile()

    var ax: UInt16 { registers[.ax] }
    var bx: UInt16 { registers[.bx] }
    var cx: UInt16 { registers[.cx] }
    var dx: UInt16 { registers[.dx] }
    var si: UInt16 { registers[.si] }
    var di: UInt16 { registers[.di] }
    var sp: UInt16 { registers[.sp] }
    var bp: UInt16 { registers[.bp] }

    private(set) var cs: UInt16 = 0
    private(set) var ds: UInt16 = 0
    private(set) var es: UInt16 = 0
    private(set) var ss: UInt16 = 0
    private(set) var ip: UInt16 = 0
    private(set) var flags = CPUFlags()

    /// The most recently fetched opcode byte, or `nil` if nothing has been
    /// fetched since reset. Exposed for inspection; not yet decoded or executed.
    private(set) var lastFetchedOpcode: UInt8?

    /// True after executing HLT or raising a temporary pre-interrupt fault.
    /// A halted CPU performs no fetches; only reset exits the state until
    /// interrupt delivery and wake-from-halt exist.
    private(set) var halted = false

    /// A temporary, observable sentinel for CPU-generated faults that cannot
    /// yet enter an interrupt handler. M35 will replace divide-error halting
    /// with interrupt-vector-0 delivery.
    private(set) var fault: CPUFault?

    /// A pending segment-override prefix that redirects the next instruction's
    /// data-operand segment. Set by the fetch/decode loop when it consumes a
    /// 0x26/0x2E/0x36/0x3E prefix, cleared once the instruction executes. Stack
    /// and code accesses never consult it.
    private(set) var segmentOverride: SegmentRegister?

    init(bus: Bus) {
        self.bus = bus
        reset()
    }

    /// Restores the CPU to its documented Intel 8086 power-on / RESET state.
    ///
    /// The reset vector is CS:IP = FFFF:0000, which the address translator maps to
    /// physical address FFFF0h — 16 bytes below the top of the 1 MB space — where
    /// the first instruction is fetched. DS, ES, SS and IP are cleared, and FLAGS
    /// is reset to 0xF002 (all condition/control flags clear, reserved bits
    /// hard-wired). The general-purpose registers are architecturally undefined at
    /// reset on real hardware; we zero them for deterministic, testable behaviour.
    func reset() {
        registers.reset()
        cs = 0xFFFF
        ds = 0
        es = 0
        ss = 0
        ip = 0
        flags = CPUFlags()
        lastFetchedOpcode = nil
        halted = false
        fault = nil
        segmentOverride = nil
    }

    /// Records a pending segment override (last prefix before an instruction
    /// wins). Consumed by the next instruction's data-operand resolution.
    func setSegmentOverride(_ segment: SegmentRegister) {
        segmentOverride = segment
    }

    /// Clears the pending override; the fetch/decode loop calls this once the
    /// prefixed instruction has executed.
    func clearSegmentOverride() {
        segmentOverride = nil
    }

    /// Fetches one opcode byte from the code stream at CS:IP through the bus and
    /// advances IP past it. This is a pure instruction *fetch* — no decoding or
    /// execution happens here.
    ///
    /// IP advances with 16-bit wraparound, so fetching past offset FFFFh wraps to
    /// 0000h within the current code segment, matching the 8086.
    @discardableResult
    func fetch() -> UInt8 {
        let address = AddressTranslator.physicalAddress(segment: cs, offset: ip)
        let opcode = bus.readByte(at: address)
        lastFetchedOpcode = opcode
        ip = ip &+ 1
        return opcode
    }

    /// Executes one decoded instruction and returns its cost in clock cycles.
    ///
    /// NOP costs 3 clocks on the 8086 and changes no state — the fetch already
    /// advanced IP past it. Unknown opcodes follow a no-op-and-advance policy
    /// (executed like NOP, at the same provisional 3-clock cost) so stepping
    /// through unimplemented code never wedges the machine; a trap mechanism
    /// can replace this once interrupts exist. HLT (2 clocks) puts the CPU
    /// into the halted state, exited only by reset for now.
    func execute(_ instruction: Instruction) -> Int {
        switch instruction {
        case .nop:
            return 3
        case .hlt:
            halted = true
            return 2
        case .movImmediateToRegister8(let register, let value):
            // MOV affects no flags; immediate-to-register costs 4 clocks.
            registers[register] = value
            return 4
        case .movImmediateToRegister16(let register, let value):
            registers[register] = value
            return 4
        case .movRegisterToRM8(let source, let destination, let eaClocks):
            // MOV reg→reg is 2 clocks; reg→memory is 9 + EA time.
            switch destination {
            case .register(let encoding):
                registers[Register8(rawValue: encoding)!] = registers[source]
                return 2
            case .memory(let address):
                bus.writeByte(registers[source], at: physicalAddress(of: resolved(address)))
                return 9 + eaClocks
            }
        case .movRegisterToRM16(let source, let destination, let eaClocks):
            switch destination {
            case .register(let encoding):
                registers[Register16(rawValue: encoding)!] = registers[source]
                return 2
            case .memory(let address):
                writeMemoryWord(registers[source], at: resolved(address))
                return 9 + eaClocks
            }
        case .movRMToRegister8(let destination, let source, let eaClocks):
            // MOV memory→reg is 8 + EA time.
            switch source {
            case .register(let encoding):
                registers[destination] = registers[Register8(rawValue: encoding)!]
                return 2
            case .memory(let address):
                registers[destination] = bus.readByte(at: physicalAddress(of: resolved(address)))
                return 8 + eaClocks
            }
        case .movRMToRegister16(let destination, let source, let eaClocks):
            switch source {
            case .register(let encoding):
                registers[destination] = registers[Register16(rawValue: encoding)!]
                return 2
            case .memory(let address):
                registers[destination] = readMemoryWord(at: resolved(address))
                return 8 + eaClocks
            }
        case .movImmediateToRM8(let destination, let value, let eaClocks):
            // MOV r/m8, imm8 (C6 /0): register 4 clocks, memory 10+EA.
            writeOperand8(value, to: destination)
            return isRegister(destination) ? 4 : 10 + eaClocks
        case .movImmediateToRM16(let destination, let value, let eaClocks):
            writeOperand16(value, to: destination)
            return isRegister(destination) ? 4 : 10 + eaClocks
        case .movMemoryOffset(let offset, let isWord, let store):
            // MOV AL/AX ↔ [DS:offset] (A0–A3); a flat 10 clocks, no flags. A
            // segment-override prefix redirects it like any data operand.
            let address = resolved(EffectiveAddress(offset: offset, defaultSegment: .ds))
            switch (store, isWord) {
            case (false, false): registers[.al] = bus.readByte(at: physicalAddress(of: address))
            case (false, true):  registers[.ax] = readMemoryWord(at: address)
            case (true, false):  bus.writeByte(registers[.al], at: physicalAddress(of: address))
            case (true, true):   writeMemoryWord(registers[.ax], at: address)
            }
            return 10
        case .moveString(let isWord):
            // The source is overrideable DS:SI; the destination is always
            // ES:DI. Read before writing so overlapping strings have the
            // architectural one-iteration ordering.
            let source = resolved(EffectiveAddress(offset: registers[.si], defaultSegment: .ds))
            let destination = EffectiveAddress(offset: registers[.di], defaultSegment: .es)
            if isWord {
                writeMemoryWord(readMemoryWord(at: source), at: destination)
            } else {
                let value = bus.readByte(at: physicalAddress(of: source))
                bus.writeByte(value, at: physicalAddress(of: destination))
            }
            adjustStringIndex(.si, isWord: isWord)
            adjustStringIndex(.di, isWord: isWord)
            return 18
        case .loadString(let isWord):
            // LODS reads from overrideable DS:SI into AL/AX.
            let source = resolved(EffectiveAddress(offset: registers[.si], defaultSegment: .ds))
            if isWord {
                registers[.ax] = readMemoryWord(at: source)
            } else {
                registers[.al] = bus.readByte(at: physicalAddress(of: source))
            }
            adjustStringIndex(.si, isWord: isWord)
            return 12
        case .storeString(let isWord):
            // STOS always writes AL/AX to ES:DI; a segment prefix cannot
            // redirect its implicit destination.
            let destination = EffectiveAddress(offset: registers[.di], defaultSegment: .es)
            if isWord {
                writeMemoryWord(registers[.ax], at: destination)
            } else {
                bus.writeByte(registers[.al], at: physicalAddress(of: destination))
            }
            adjustStringIndex(.di, isWord: isWord)
            return 11
        case .compareString(let isWord):
            // CMPS subtracts the fixed ES:DI destination from the
            // overrideable DS:SI source, updates flags, and writes neither.
            let source = resolved(EffectiveAddress(offset: registers[.si], defaultSegment: .ds))
            let destination = EffectiveAddress(offset: registers[.di], defaultSegment: .es)
            if isWord {
                let outcome = ALU.subtract16(
                    readMemoryWord(at: source),
                    readMemoryWord(at: destination)
                )
                flags.applyArithmetic(outcome.flags)
            } else {
                let outcome = ALU.subtract8(
                    bus.readByte(at: physicalAddress(of: source)),
                    bus.readByte(at: physicalAddress(of: destination))
                )
                flags.applyArithmetic(outcome.flags)
            }
            adjustStringIndex(.si, isWord: isWord)
            adjustStringIndex(.di, isWord: isWord)
            return 22
        case .scanString(let isWord):
            // SCAS subtracts the fixed ES:DI element from AL/AX. Segment
            // overrides never redirect the implicit destination.
            let destination = EffectiveAddress(offset: registers[.di], defaultSegment: .es)
            if isWord {
                flags.applyArithmetic(ALU.subtract16(
                    registers[.ax],
                    readMemoryWord(at: destination)
                ).flags)
            } else {
                flags.applyArithmetic(ALU.subtract8(
                    registers[.al],
                    bus.readByte(at: physicalAddress(of: destination))
                ).flags)
            }
            adjustStringIndex(.di, isWord: isWord)
            return 15
        case .exchangeRM8(let register, let rm, let eaClocks):
            // XCHG swaps the two operands; no flags. reg↔reg 4, mem 17+EA.
            let temp = registers[register]
            registers[register] = readOperand8(rm)
            writeOperand8(temp, to: rm)
            return isRegister(rm) ? 4 : 17 + eaClocks
        case .exchangeRM16(let register, let rm, let eaClocks):
            let temp = registers[register]
            registers[register] = readOperand16(rm)
            writeOperand16(temp, to: rm)
            return isRegister(rm) ? 4 : 17 + eaClocks
        case .exchangeAXWithRegister(let register):
            // XCHG AX, reg one-byte form: 3 clocks.
            let temp = registers[.ax]
            registers[.ax] = registers[register]
            registers[register] = temp
            return 3
        case .movSegmentToRM(let destination, let segment, let eaClocks):
            // MOV r/m16, sreg — register 2 clocks, memory 9+EA. No flags.
            writeOperand16(segmentValue(segment), to: destination)
            return isRegister(destination) ? 2 : 9 + eaClocks
        case .movRMToSegment(let segment, let source, let eaClocks):
            // MOV sreg, r/m16 — register 2 clocks, memory 8+EA. No flags.
            writeSegment(readOperand16(source), to: segment)
            return isRegister(source) ? 2 : 8 + eaClocks
        case .loadEffectiveAddress(let destination, let offset, let eaClocks):
            // The decoder has already performed the address arithmetic. LEA
            // neither resolves a segment nor accesses the bus.
            registers[destination] = offset
            return 2 + eaClocks
        case .loadFarPointer(let destination, let segment, let source, let eaClocks):
            // Read the complete pointer before either architectural destination
            // changes (especially important when LDS also supplies the source
            // segment or its address used the destination register).
            let pointer = readFarPointer(from: source)
            registers[destination] = pointer.offset
            writeSegment(pointer.segment, to: segment)
            return 16 + eaClocks
        case .pushSegment(let segment):
            push16(segmentValue(segment))
            return 10
        case .popSegment(let segment):
            writeSegment(pop16(), to: segment)
            return 8
        case .pushFlags:
            push16(flags.rawValue)
            return 10
        case .popFlags:
            flags = CPUFlags(rawValue: pop16())
            return 8
        case .loadStatusFlagsIntoAH:
            registers[.ah] = flags.statusByte
            return 4
        case .storeAHIntoStatusFlags:
            flags.applyStatusByte(registers[.ah])
            return 4
        case .clearFlag(let flag):
            flags[flag] = false
            return 2
        case .setFlag(let flag):
            flags[flag] = true
            return 2
        case .complementCarry:
            flags[.carry].toggle()
            return 2
        case .shiftRotate8(let operation, let destination, let countSource, let eaClocks):
            let count: UInt8 = countSource == .one ? 1 : registers[.cl]
            let outcome = ALU.shiftRotate8(
                readOperand8(destination),
                operation: operation,
                count: count,
                carryIn: flags[.carry]
            )
            if count != 0 {
                writeOperand8(outcome.result, to: destination)
            }
            flags.applyShiftRotate(outcome.flags)
            return shiftRotateClocks(for: destination, countSource: countSource, count: count, eaClocks: eaClocks)
        case .shiftRotate16(let operation, let destination, let countSource, let eaClocks):
            let count: UInt8 = countSource == .one ? 1 : registers[.cl]
            let outcome = ALU.shiftRotate16(
                readOperand16(destination),
                operation: operation,
                count: count,
                carryIn: flags[.carry]
            )
            if count != 0 {
                writeOperand16(outcome.result, to: destination)
            }
            flags.applyShiftRotate(outcome.flags)
            return shiftRotateClocks(for: destination, countSource: countSource, count: count, eaClocks: eaClocks)
        case .testImmediateRM8(let destination, let immediate, let eaClocks):
            let (_, arithmeticFlags) = ALU.and8(readOperand8(destination), immediate)
            flags.applyArithmetic(arithmeticFlags)
            return isRegister(destination) ? 5 : 11 + eaClocks
        case .testImmediateRM16(let destination, let immediate, let eaClocks):
            let (_, arithmeticFlags) = ALU.and16(readOperand16(destination), immediate)
            flags.applyArithmetic(arithmeticFlags)
            return isRegister(destination) ? 5 : 11 + eaClocks
        case .unary8(let operation, let operand, let eaClocks):
            executeUnary8(operation, operand: operand)
            return unaryClocks(operation, isWord: false, isMemory: !isRegister(operand), eaClocks: eaClocks)
        case .unary16(let operation, let operand, let eaClocks):
            executeUnary16(operation, operand: operand)
            return unaryClocks(operation, isWord: true, isMemory: !isRegister(operand), eaClocks: eaClocks)
        case .aluRegisterToRM8(let op, let source, let destination, let eaClocks):
            // ALU r/m8, r8 — a memory destination is read-modify-write
            // (16+EA), except CMP which only reads (9+EA).
            let (result, arithmeticFlags) = perform8(op, readOperand8(destination), registers[source])
            if op.writesResult {
                writeOperand8(result, to: destination)
            }
            flags.applyArithmetic(arithmeticFlags)
            return isRegister(destination) ? 3 : (op.writesResult ? 16 : 9) + eaClocks
        case .aluRegisterToRM16(let op, let source, let destination, let eaClocks):
            let (result, arithmeticFlags) = perform16(op, readOperand16(destination), registers[source])
            if op.writesResult {
                writeOperand16(result, to: destination)
            }
            flags.applyArithmetic(arithmeticFlags)
            return isRegister(destination) ? 3 : (op.writesResult ? 16 : 9) + eaClocks
        case .aluRMToRegister8(let op, let destination, let source, let eaClocks):
            let (result, arithmeticFlags) = perform8(op, registers[destination], readOperand8(source))
            if op.writesResult {
                registers[destination] = result
            }
            flags.applyArithmetic(arithmeticFlags)
            return isRegister(source) ? 3 : 9 + eaClocks
        case .aluRMToRegister16(let op, let destination, let source, let eaClocks):
            let (result, arithmeticFlags) = perform16(op, registers[destination], readOperand16(source))
            if op.writesResult {
                registers[destination] = result
            }
            flags.applyArithmetic(arithmeticFlags)
            return isRegister(source) ? 3 : 9 + eaClocks
        case .aluImmediateToRM8(let op, let destination, let immediate, let eaClocks):
            // ALU r/m, imm — register 4 clocks; a memory destination is
            // read-modify-write (17+EA), except CMP which only reads (10+EA).
            let (result, arithmeticFlags) = perform8(op, readOperand8(destination), immediate)
            if op.writesResult {
                writeOperand8(result, to: destination)
            }
            flags.applyArithmetic(arithmeticFlags)
            return isRegister(destination) ? 4 : (op.writesResult ? 17 : 10) + eaClocks
        case .aluImmediateToRM16(let op, let destination, let immediate, let eaClocks):
            let (result, arithmeticFlags) = perform16(op, readOperand16(destination), immediate)
            if op.writesResult {
                writeOperand16(result, to: destination)
            }
            flags.applyArithmetic(arithmeticFlags)
            return isRegister(destination) ? 4 : (op.writesResult ? 17 : 10) + eaClocks
        case .incRegister16(let register):
            // INC/DEC update OF/SF/ZF/AF/PF like ADD/SUB by 1 but leave CF
            // untouched — the documented 8086 quirk.
            let (result, arithmeticFlags) = ALU.add16(registers[register], 1)
            registers[register] = result
            flags.applyArithmeticPreservingCarry(arithmeticFlags)
            return 3
        case .decRegister16(let register):
            let (result, arithmeticFlags) = ALU.subtract16(registers[register], 1)
            registers[register] = result
            flags.applyArithmeticPreservingCarry(arithmeticFlags)
            return 3
        case .incRM8(let destination, let eaClocks):
            let outcome = ALU.add8(readOperand8(destination), 1)
            writeOperand8(outcome.result, to: destination)
            flags.applyArithmeticPreservingCarry(outcome.flags)
            return isRegister(destination) ? 3 : 15 + eaClocks
        case .decRM8(let destination, let eaClocks):
            let outcome = ALU.subtract8(readOperand8(destination), 1)
            writeOperand8(outcome.result, to: destination)
            flags.applyArithmeticPreservingCarry(outcome.flags)
            return isRegister(destination) ? 3 : 15 + eaClocks
        case .incRM16(let destination, let eaClocks):
            let outcome = ALU.add16(readOperand16(destination), 1)
            writeOperand16(outcome.result, to: destination)
            flags.applyArithmeticPreservingCarry(outcome.flags)
            return isRegister(destination) ? 3 : 15 + eaClocks
        case .decRM16(let destination, let eaClocks):
            let outcome = ALU.subtract16(readOperand16(destination), 1)
            writeOperand16(outcome.result, to: destination)
            flags.applyArithmeticPreservingCarry(outcome.flags)
            return isRegister(destination) ? 3 : 15 + eaClocks
        case .pushRegister16(let register):
            // The register is read *after* SP moves, so PUSH SP stores the
            // decremented value — the documented 8086 quirk (80286+ store the
            // old value).
            registers[.sp] = registers[.sp] &- 2
            writeMemoryWord(registers[register], at: EffectiveAddress(offset: registers[.sp], defaultSegment: .ss))
            return 11
        case .popRegister16(let register):
            registers[register] = pop16()
            return 8
        case .pushRM16(let source, let eaClocks):
            if source == .register(Register16.sp.rawValue) {
                // Like the one-byte form, FF /6 PUSH SP observes SP after
                // decrementing it on the original 8086.
                registers[.sp] = registers[.sp] &- 2
                writeMemoryWord(registers[.sp], at: EffectiveAddress(offset: registers[.sp], defaultSegment: .ss))
            } else {
                // Resolve/read a memory source before stack mutation.
                push16(readOperand16(source))
            }
            return isRegister(source) ? 11 : 16 + eaClocks
        case .popRM16(let destination, let eaClocks):
            // Stack traffic is SS-relative; only the destination goes through
            // the regular operand helper (and therefore a segment override).
            let value = pop16()
            writeOperand16(value, to: destination)
            return isRegister(destination) ? 8 : 17 + eaClocks
        case .callNearRelative(let displacement):
            // IP already points past the displacement word, so it is the
            // return address; push it, then branch relative with 16-bit wrap.
            push16(ip)
            ip = ip &+ UInt16(bitPattern: displacement)
            return 19
        case .callNearIndirect(let source, let eaClocks):
            // Resolve the absolute target before PUSH mutates SP. This is
            // observable for CALL SP and keeps memory-source access ordered.
            let target = readOperand16(source)
            push16(ip)
            ip = target
            return isRegister(source) ? 16 : 21 + eaClocks
        case .callFar(let offset, let segment):
            // Push CS first so the final stack top is the return IP consumed
            // first by RETF.
            push16(cs)
            push16(ip)
            cs = segment
            ip = offset
            return 28
        case .callFarIndirect(let source, let eaClocks):
            // Fetch both pointer words before stack traffic can overwrite them.
            let target = readFarPointer(from: source)
            push16(cs)
            push16(ip)
            cs = target.segment
            ip = target.offset
            return 37 + eaClocks
        case .returnNear:
            ip = pop16()
            return 16
        case .returnNearAdjust(let adjustment):
            ip = pop16()
            registers[.sp] = registers[.sp] &+ adjustment
            return 20
        case .returnFar:
            ip = pop16()
            cs = pop16()
            return 26
        case .returnFarAdjust(let adjustment):
            ip = pop16()
            cs = pop16()
            registers[.sp] = registers[.sp] &+ adjustment
            return 25
        case .jumpConditional(let condition, let displacement):
            // IP already points past the displacement byte; a taken branch
            // adds the sign-extended offset with 16-bit wrap.
            guard condition.isSatisfied(by: flags) else { return 4 }
            ip = ip &+ UInt16(bitPattern: Int16(displacement))
            return 16
        case .jumpShort(let displacement):
            ip = ip &+ UInt16(bitPattern: Int16(displacement))
            return 15
        case .jumpNear(let displacement):
            // IP already points past the disp16; branch relative with wrap.
            ip = ip &+ UInt16(bitPattern: displacement)
            return 15
        case .jumpNearIndirect(let source, let eaClocks):
            ip = readOperand16(source)
            return isRegister(source) ? 11 : 18 + eaClocks
        case .jumpFar(let offset, let segment):
            // Direct intersegment: load CS and IP together, no flags touched.
            cs = segment
            ip = offset
            return 15
        case .jumpFarIndirect(let source, let eaClocks):
            let target = readFarPointer(from: source)
            cs = target.segment
            ip = target.offset
            return 24 + eaClocks
        case .loop(let condition, let displacement):
            // CX decrements unconditionally and without touching flags; the
            // branch tests the *new* CX (so entering with CX=0 wraps to
            // 0xFFFF and loops 65536 times, like real silicon).
            registers[.cx] = registers[.cx] &- 1
            guard registers[.cx] != 0, condition.isSatisfied(by: flags) else {
                return condition.notTakenClocks
            }
            ip = ip &+ UInt16(bitPattern: Int16(displacement))
            return condition.takenClocks
        case .jumpIfCXZero(let displacement):
            guard registers[.cx] == 0 else { return 6 }
            ip = ip &+ UInt16(bitPattern: Int16(displacement))
            return 18
        case .unknown:
            return 3
        }
    }

    /// Writes a segment register. Used by tests today; MOV sreg (0x8E) and
    /// POP sreg will route through it when they land.
    func writeSegment(_ value: UInt16, to segment: SegmentRegister) {
        switch segment {
        case .es: es = value
        case .cs: cs = value
        case .ss: ss = value
        case .ds: ds = value
        }
    }

    /// The stack lives at SS:SP and grows downward: push is
    /// decrement-then-write, pop is read-then-increment, both wrapping at
    /// 16 bits within the stack segment.
    private func push16(_ value: UInt16) {
        registers[.sp] = registers[.sp] &- 2
        writeMemoryWord(value, at: EffectiveAddress(offset: registers[.sp], defaultSegment: .ss))
    }

    private func pop16() -> UInt16 {
        let value = readMemoryWord(at: EffectiveAddress(offset: registers[.sp], defaultSegment: .ss))
        registers[.sp] = registers[.sp] &+ 2
        return value
    }

    /// Advances an implicit string index by the operand width, or retreats it
    /// when DF is set. Original 8086 arithmetic wraps within 16 bits.
    private func adjustStringIndex(_ register: Register16, isWord: Bool) {
        let amount: UInt16 = isWord ? 2 : 1
        registers[register] = flags[.direction]
            ? registers[register] &- amount
            : registers[register] &+ amount
    }

    private func perform8(_ op: ALUBinaryOp, _ a: UInt8, _ b: UInt8) -> (UInt8, ArithmeticFlags) {
        switch op {
        case .add: return ALU.add8(a, b)
        case .adc: return ALU.addWithCarry8(a, b, carryIn: flags[.carry])
        case .sbb: return ALU.subtractWithBorrow8(a, b, borrowIn: flags[.carry])
        case .sub, .cmp: return ALU.subtract8(a, b)
        case .and, .test: return ALU.and8(a, b)
        case .or: return ALU.or8(a, b)
        case .xor: return ALU.xor8(a, b)
        }
    }

    private func perform16(_ op: ALUBinaryOp, _ a: UInt16, _ b: UInt16) -> (UInt16, ArithmeticFlags) {
        switch op {
        case .add: return ALU.add16(a, b)
        case .adc: return ALU.addWithCarry16(a, b, carryIn: flags[.carry])
        case .sbb: return ALU.subtractWithBorrow16(a, b, borrowIn: flags[.carry])
        case .sub, .cmp: return ALU.subtract16(a, b)
        case .and, .test: return ALU.and16(a, b)
        case .or: return ALU.or16(a, b)
        case .xor: return ALU.xor16(a, b)
        }
    }

    private func isRegister(_ operand: ModRMOperand) -> Bool {
        if case .register = operand { return true }
        return false
    }

    private func shiftRotateClocks(
        for operand: ModRMOperand,
        countSource: ShiftCount,
        count: UInt8,
        eaClocks: Int
    ) -> Int {
        switch (isRegister(operand), countSource) {
        case (true, .one): 2
        case (false, .one): 15 + eaClocks
        case (true, .cl): 8 + 4 * Int(count)
        case (false, .cl): 20 + eaClocks + 4 * Int(count)
        }
    }

    private func executeUnary8(_ operation: UnaryOperation, operand: ModRMOperand) {
        let source = readOperand8(operand)
        switch operation {
        case .not:
            writeOperand8(~source, to: operand)
        case .negate:
            let outcome = ALU.subtract8(0, source)
            writeOperand8(outcome.result, to: operand)
            flags.applyArithmetic(outcome.flags)
        case .multiplyUnsigned:
            let product = UInt16(registers[.al]) * UInt16(source)
            registers[.ax] = product
            applyMultiplyFlags(product >> 8 != 0)
        case .multiplySigned:
            let product = Int16(Int8(bitPattern: registers[.al])) * Int16(Int8(bitPattern: source))
            registers[.ax] = UInt16(bitPattern: product)
            applyMultiplyFlags(product < Int16(Int8.min) || product > Int16(Int8.max))
        case .divideUnsigned:
            let divisor = UInt16(source)
            guard divisor != 0 else { return raiseDivideError() }
            let dividend = registers[.ax]
            let quotient = dividend / divisor
            guard quotient <= UInt16(UInt8.max) else { return raiseDivideError() }
            registers[.al] = UInt8(quotient)
            registers[.ah] = UInt8(dividend % divisor)
        case .divideSigned:
            let divisor = Int32(Int8(bitPattern: source))
            guard divisor != 0 else { return raiseDivideError() }
            let dividend = Int32(Int16(bitPattern: registers[.ax]))
            let quotient = dividend / divisor
            // Original 8086 silicon faults on the most-negative quotient too.
            guard quotient > Int32(Int8.min), quotient <= Int32(Int8.max) else {
                return raiseDivideError()
            }
            registers[.al] = UInt8(bitPattern: Int8(quotient))
            registers[.ah] = UInt8(bitPattern: Int8(dividend % divisor))
        }
    }

    private func executeUnary16(_ operation: UnaryOperation, operand: ModRMOperand) {
        let source = readOperand16(operand)
        switch operation {
        case .not:
            writeOperand16(~source, to: operand)
        case .negate:
            let outcome = ALU.subtract16(0, source)
            writeOperand16(outcome.result, to: operand)
            flags.applyArithmetic(outcome.flags)
        case .multiplyUnsigned:
            let product = UInt32(registers[.ax]) * UInt32(source)
            registers[.ax] = UInt16(truncatingIfNeeded: product)
            registers[.dx] = UInt16(product >> 16)
            applyMultiplyFlags(product >> 16 != 0)
        case .multiplySigned:
            let product = Int32(Int16(bitPattern: registers[.ax])) * Int32(Int16(bitPattern: source))
            let bits = UInt32(bitPattern: product)
            registers[.ax] = UInt16(truncatingIfNeeded: bits)
            registers[.dx] = UInt16(bits >> 16)
            applyMultiplyFlags(product < Int32(Int16.min) || product > Int32(Int16.max))
        case .divideUnsigned:
            let divisor = UInt32(source)
            guard divisor != 0 else { return raiseDivideError() }
            let dividend = UInt32(registers[.dx]) << 16 | UInt32(registers[.ax])
            let quotient = dividend / divisor
            guard quotient <= UInt32(UInt16.max) else { return raiseDivideError() }
            registers[.ax] = UInt16(quotient)
            registers[.dx] = UInt16(dividend % divisor)
        case .divideSigned:
            let divisor = Int64(Int16(bitPattern: source))
            guard divisor != 0 else { return raiseDivideError() }
            let bits = UInt32(registers[.dx]) << 16 | UInt32(registers[.ax])
            let dividend = Int64(Int32(bitPattern: bits))
            let quotient = dividend / divisor
            guard quotient > Int64(Int16.min), quotient <= Int64(Int16.max) else {
                return raiseDivideError()
            }
            registers[.ax] = UInt16(bitPattern: Int16(quotient))
            registers[.dx] = UInt16(bitPattern: Int16(dividend % divisor))
        }
    }

    private func applyMultiplyFlags(_ hasSignificantHighHalf: Bool) {
        flags[.carry] = hasSignificantHighHalf
        flags[.overflow] = hasSignificantHighHalf
    }

    private func raiseDivideError() {
        fault = .divideError
        halted = true
    }

    /// MUL/DIV costs are operand-dependent ranges on the 8086. Until the core
    /// models the microcode bit-by-bit, charge the rounded midpoint of Intel's
    /// documented range; memory forms add their six-clock operand-access base
    /// plus EA time.
    private func unaryClocks(
        _ operation: UnaryOperation,
        isWord: Bool,
        isMemory: Bool,
        eaClocks: Int
    ) -> Int {
        let registerClocks: Int
        switch (operation, isWord) {
        case (.not, _), (.negate, _): registerClocks = 3
        case (.multiplyUnsigned, false): registerClocks = 74
        case (.multiplyUnsigned, true): registerClocks = 126
        case (.multiplySigned, false): registerClocks = 89
        case (.multiplySigned, true): registerClocks = 141
        case (.divideUnsigned, false): registerClocks = 85
        case (.divideUnsigned, true): registerClocks = 153
        case (.divideSigned, false): registerClocks = 107
        case (.divideSigned, true): registerClocks = 175
        }
        guard isMemory else { return registerClocks }
        return (operation == .not || operation == .negate ? 16 : registerClocks + 6) + eaClocks
    }

    private func readOperand8(_ operand: ModRMOperand) -> UInt8 {
        switch operand {
        case .register(let encoding): return registers[Register8(rawValue: encoding)!]
        case .memory(let address): return bus.readByte(at: physicalAddress(of: resolved(address)))
        }
    }

    private func writeOperand8(_ value: UInt8, to operand: ModRMOperand) {
        switch operand {
        case .register(let encoding): registers[Register8(rawValue: encoding)!] = value
        case .memory(let address): bus.writeByte(value, at: physicalAddress(of: resolved(address)))
        }
    }

    private func readOperand16(_ operand: ModRMOperand) -> UInt16 {
        switch operand {
        case .register(let encoding): return registers[Register16(rawValue: encoding)!]
        case .memory(let address): return readMemoryWord(at: resolved(address))
        }
    }

    private func writeOperand16(_ value: UInt16, to operand: ModRMOperand) {
        switch operand {
        case .register(let encoding): registers[Register16(rawValue: encoding)!] = value
        case .memory(let address): writeMemoryWord(value, at: resolved(address))
        }
    }

    /// Reads an m16:16 pointer using one resolved segment for both words. The
    /// second word starts at offset+2 with 16-bit wrap within that segment.
    private func readFarPointer(from operand: ModRMOperand) -> (offset: UInt16, segment: UInt16) {
        guard case .memory(let address) = operand else {
            preconditionFailure("Far indirect transfers require a memory operand")
        }
        let pointer = resolved(address)
        let offset = readMemoryWord(at: pointer)
        let segmentAddress = EffectiveAddress(
            offset: pointer.offset &+ 2,
            defaultSegment: pointer.defaultSegment
        )
        return (offset, readMemoryWord(at: segmentAddress))
    }

    /// Applies a pending segment override to a data operand's address. Stack
    /// and code accesses build their own addresses and never call this, so they
    /// always use SS/CS regardless of any prefix.
    private func resolved(_ address: EffectiveAddress) -> EffectiveAddress {
        guard let segmentOverride else { return address }
        return EffectiveAddress(offset: address.offset, defaultSegment: segmentOverride)
    }

    private func segmentValue(_ segment: SegmentRegister) -> UInt16 {
        switch segment {
        case .es: return es
        case .cs: return cs
        case .ss: return ss
        case .ds: return ds
        }
    }

    private func physicalAddress(of address: EffectiveAddress) -> UInt32 {
        AddressTranslator.physicalAddress(
            segment: segmentValue(address.defaultSegment),
            offset: address.offset
        )
    }

    /// Word accesses are two byte accesses whose offsets wrap at 16 bits
    /// within the segment, matching the 8086.
    private func readMemoryWord(at address: EffectiveAddress) -> UInt16 {
        let segment = segmentValue(address.defaultSegment)
        let low = bus.readByte(at: AddressTranslator.physicalAddress(segment: segment, offset: address.offset))
        let high = bus.readByte(at: AddressTranslator.physicalAddress(segment: segment, offset: address.offset &+ 1))
        return UInt16(high) << 8 | UInt16(low)
    }

    private func writeMemoryWord(_ value: UInt16, at address: EffectiveAddress) {
        let segment = segmentValue(address.defaultSegment)
        bus.writeByte(UInt8(value & 0xFF), at: AddressTranslator.physicalAddress(segment: segment, offset: address.offset))
        bus.writeByte(UInt8(value >> 8), at: AddressTranslator.physicalAddress(segment: segment, offset: address.offset &+ 1))
    }

    func dumpState() -> CPUStateSnapshot {
        CPUStateSnapshot(
            ax: ax,
            bx: bx,
            cx: cx,
            dx: dx,
            si: si,
            di: di,
            sp: sp,
            bp: bp,
            cs: cs,
            ds: ds,
            es: es,
            ss: ss,
            ip: ip,
            flags: flags,
            lastFetchedOpcode: lastFetchedOpcode,
            halted: halted,
            fault: fault
        )
    }
}
