import Testing
@testable import Sector_Zero

/// Milestone 1 — authentic Intel 8086 power-on / RESET state.
///
/// The 8086 begins execution at the reset vector CS:IP = FFFF:0000 (physical
/// FFFF0h) with every condition and control flag cleared. References: the Intel
/// 8086 documentation and https://en.wikipedia.org/wiki/Reset_vector.
struct CPUResetTests {

    @Test("Reset vector is CS:IP = FFFF:0000")
    func resetVector() {
        let cpu = Machine().cpu
        #expect(cpu.cs == 0xFFFF)
        #expect(cpu.ip == 0x0000)
    }

    @Test("Reset vector translates to physical address FFFF0h")
    func resetPhysicalAddress() {
        #expect(Machine().currentCodeAddress == 0xFFFF0)
    }

    @Test("Data, extra and stack segments are cleared on reset")
    func segmentRegistersCleared() {
        let cpu = Machine().cpu
        #expect(cpu.ds == 0)
        #expect(cpu.es == 0)
        #expect(cpu.ss == 0)
    }

    @Test("General, index and pointer registers are zeroed on reset")
    func workingRegistersZeroed() {
        let cpu = Machine().cpu
        #expect(cpu.ax == 0)
        #expect(cpu.bx == 0)
        #expect(cpu.cx == 0)
        #expect(cpu.dx == 0)
        #expect(cpu.si == 0)
        #expect(cpu.di == 0)
        #expect(cpu.sp == 0)
        #expect(cpu.bp == 0)
    }

    @Test("FLAGS resets to 0xF002 with all condition/control flags clear")
    func flagsResetValue() {
        let flags = Machine().cpu.flags
        #expect(flags.rawValue == 0xF002)
        #expect(flags.hexValue == "F002")
        #expect(flags.activeFlags.isEmpty)
    }

    @Test("Every named flag reads as clear after reset", arguments: CPUFlag.allCases)
    func namedFlagsClear(_ flag: CPUFlag) {
        #expect(Machine().cpu.flags[flag] == false)
    }

    @Test("Cycle counter starts at zero")
    func cycleCounterZero() {
        #expect(Machine().cycleCount == 0)
    }
}

/// The 8086 hard-wires bit 1 and bits 12–15 of the FLAGS register to 1; software
/// can never clear them. These invariants guard that behaviour independently of a
/// CPU reset, so they hold for any `CPUFlags` value the emulator produces.
struct CPUFlagsReservedBitsTests {
    private static let reservedMask: UInt16 = 0xF002

    @Test("Default-constructed flags carry the reserved bits")
    func defaultReservedBits() {
        #expect(CPUFlags().rawValue == Self.reservedMask)
    }

    @Test("Reserved bits are forced even from an all-zero raw value")
    func reservedBitsForcedFromZero() {
        #expect(CPUFlags(rawValue: 0x0000).rawValue == Self.reservedMask)
    }

    @Test("Reserved-zero bits are cleared from an all-one raw value")
    func reservedZeroBitsClearedFromOnes() {
        #expect(CPUFlags(rawValue: 0xFFFF).rawValue == 0xFFD7)
    }

    @Test("Reserved bits survive clearing a condition flag")
    func reservedBitsSurviveClear() {
        var flags = CPUFlags()
        flags[.carry] = true
        flags[.carry] = false
        #expect(flags.rawValue & Self.reservedMask == Self.reservedMask)
    }

    @Test("Setting then clearing a flag round-trips without disturbing reserved bits")
    func flagRoundTrip() {
        var flags = CPUFlags()
        #expect(flags[.zero] == false)

        flags[.zero] = true
        #expect(flags[.zero] == true)
        #expect(flags.rawValue == Self.reservedMask | CPUFlag.zero.mask)

        flags[.zero] = false
        #expect(flags[.zero] == false)
        #expect(flags.rawValue == Self.reservedMask)
    }
}
