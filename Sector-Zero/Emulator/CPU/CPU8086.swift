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

    /// True after executing HLT. A halted CPU performs no fetches; only reset
    /// exits the state until interrupt-driven wake-from-halt exists.
    private(set) var halted = false

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
                bus.writeByte(registers[source], at: physicalAddress(of: address))
                return 9 + eaClocks
            }
        case .movRegisterToRM16(let source, let destination, let eaClocks):
            switch destination {
            case .register(let encoding):
                registers[Register16(rawValue: encoding)!] = registers[source]
                return 2
            case .memory(let address):
                writeMemoryWord(registers[source], at: address)
                return 9 + eaClocks
            }
        case .movRMToRegister8(let destination, let source, let eaClocks):
            // MOV memory→reg is 8 + EA time.
            switch source {
            case .register(let encoding):
                registers[destination] = registers[Register8(rawValue: encoding)!]
                return 2
            case .memory(let address):
                registers[destination] = bus.readByte(at: physicalAddress(of: address))
                return 8 + eaClocks
            }
        case .movRMToRegister16(let destination, let source, let eaClocks):
            switch source {
            case .register(let encoding):
                registers[destination] = registers[Register16(rawValue: encoding)!]
                return 2
            case .memory(let address):
                registers[destination] = readMemoryWord(at: address)
                return 8 + eaClocks
            }
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
            halted: halted
        )
    }
}
