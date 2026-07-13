import Testing
@testable import Sector_Zero

/// Milestone 6 — register file with byte + word access.
///
/// The 8086's first four general registers are pairs: AX = AH:AL, BX = BH:BL,
/// CX = CH:CL, DX = DH:DL, with the high byte in bits 15–8 and the low byte in
/// bits 7–0. SI/DI/SP/BP are word-only. The register file is a value type and
/// is the storage every future instruction will read and write operands through.
struct RegisterFileTests {
    /// (word register, its high half, its low half)
    private static let pairs: [(Register16, Register8, Register8)] = [
        (.ax, .ah, .al),
        (.bx, .bh, .bl),
        (.cx, .ch, .cl),
        (.dx, .dh, .dl),
    ]

    @Test("All registers are zero in a fresh file")
    func freshFileIsZeroed() {
        let file = RegisterFile()
        for register in Register16.allCases {
            #expect(file[register] == 0)
        }
        for register in Register8.allCases {
            #expect(file[register] == 0)
        }
    }

    @Test("Word write is readable back", arguments: Register16.allCases)
    func wordRoundTrip(register: Register16) {
        var file = RegisterFile()
        file[register] = 0xBEEF
        #expect(file[register] == 0xBEEF)
    }

    @Test("Byte halves compose the word with correct high/low mapping")
    func byteWritesComposeWord() {
        for (word, high, low) in Self.pairs {
            var file = RegisterFile()
            file[low] = 0x34
            file[high] = 0x12
            #expect(file[word] == 0x1234)
        }
    }

    @Test("Word writes decompose into the correct byte halves")
    func wordWriteDecomposesIntoBytes() {
        for (word, high, low) in Self.pairs {
            var file = RegisterFile()
            file[word] = 0xABCD
            #expect(file[high] == 0xAB)
            #expect(file[low] == 0xCD)
        }
    }

    @Test("Writing the low byte preserves the high byte and vice versa")
    func byteWritePreservesOtherHalf() {
        for (word, high, low) in Self.pairs {
            var file = RegisterFile()
            file[word] = 0x1234
            file[low] = 0xFF
            #expect(file[word] == 0x12FF)
            file[high] = 0xEE
            #expect(file[word] == 0xEEFF)
        }
    }

    @Test("Writes do not disturb unrelated registers")
    func writesAreIsolated() {
        var file = RegisterFile()
        for register in Register16.allCases {
            file[register] = 0x5A5A
        }
        file[.ax] = 0x1111
        file[.ah] = 0x22

        #expect(file[.ax] == 0x2211)
        for register in Register16.allCases where register != .ax {
            #expect(file[register] == 0x5A5A)
        }
    }

    @Test("reset() zeroes every register")
    func resetZeroesAll() {
        var file = RegisterFile()
        for register in Register16.allCases {
            file[register] = 0xFFFF
        }
        file.reset()
        for register in Register16.allCases {
            #expect(file[register] == 0)
        }
    }

    @Test("CPU8086 general registers are backed by the register file")
    func cpuUsesRegisterFile() {
        let machine = Machine()
        // The CPU still exposes word registers for the snapshot/inspector.
        #expect(machine.cpu.ax == 0)
        #expect(machine.cpu.registers[.ax] == 0)
        #expect(machine.cpu.registers[.al] == 0)
    }

    @Test("CPU reset zeroes the register file")
    func cpuResetZeroesFile() {
        let machine = Machine()
        machine.cpu.reset()
        for register in Register16.allCases {
            #expect(machine.cpu.registers[register] == 0)
        }
    }
}
