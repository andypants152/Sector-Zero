import Foundation

final class CPU8086 {
    // The CPU owns a bus reference now so future instruction execution has one
    // path to memory and devices. This milestone only models visible state.
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

    init(bus: Bus = EmulatorBus()) {
        self.bus = bus
        reset()
    }

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
            flags: flags
        )
    }
}
