import Foundation

final class CPU8086 {
    // The CPU only talks to memory and devices through this bus boundary.
    private let bus: Bus

    private(set) var ax: UInt16 = 0
    private(set) var bx: UInt16 = 0
    private(set) var cx: UInt16 = 0
    private(set) var dx: UInt16 = 0
    private(set) var si: UInt16 = 0
    private(set) var di: UInt16 = 0
    private(set) var sp: UInt16 = 0
    private(set) var bp: UInt16 = 0
    private(set) var cs: UInt16 = 0
    private(set) var ds: UInt16 = 0
    private(set) var es: UInt16 = 0
    private(set) var ss: UInt16 = 0
    private(set) var ip: UInt16 = 0
    private(set) var flags = CPUFlags()

    /// The most recently fetched opcode byte, or `nil` if nothing has been
    /// fetched since reset. Exposed for inspection; not yet decoded or executed.
    private(set) var lastFetchedOpcode: UInt8?

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
        ax = 0
        bx = 0
        cx = 0
        dx = 0
        si = 0
        di = 0
        sp = 0
        bp = 0
        cs = 0xFFFF
        ds = 0
        es = 0
        ss = 0
        ip = 0
        flags = CPUFlags()
        lastFetchedOpcode = nil
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
    /// can replace this once interrupts exist. HLT decodes but does not halt
    /// yet — the halted run-state lands in milestone 5.
    func execute(_ instruction: Instruction) -> Int {
        switch instruction {
        case .nop:
            return 3
        case .hlt:
            // Milestone 5 gives HLT its halted run-state; until then it is
            // treated like an unknown opcode.
            return 3
        case .unknown:
            return 3
        }
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
            lastFetchedOpcode: lastFetchedOpcode
        )
    }
}
