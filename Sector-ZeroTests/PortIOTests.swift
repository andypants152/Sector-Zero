import Testing
@testable import Sector_Zero

private enum PortEvent: Equatable {
    case readByte(UInt16)
    case readWord(UInt16)
    case writeByte(UInt16, UInt8)
    case writeWord(UInt16, UInt16)
}

private final class SpyPortDevice: IOPortDevice {
    var byteValue: UInt8 = 0
    var wordValue: UInt16 = 0
    private(set) var events: [PortEvent] = []

    func readByte(from port: UInt16) -> UInt8 {
        events.append(.readByte(port))
        return byteValue
    }

    func readWord(from port: UInt16) -> UInt16 {
        events.append(.readWord(port))
        return wordValue
    }

    func writeByte(_ value: UInt8, to port: UInt16) {
        events.append(.writeByte(port, value))
    }

    func writeWord(_ value: UInt16, to port: UInt16) {
        events.append(.writeWord(port, value))
    }
}

/// Milestone 38 — bus-owned I/O ports and all 8086 IN/OUT forms.
struct PortIOTests {
    private let resetVector: UInt32 = 0xFFFF0

    private func machineWithOpcodes(_ opcodes: [UInt8]) -> Machine {
        let machine = Machine()
        for (offset, opcode) in opcodes.enumerated() {
            machine.bus.writeByte(
                opcode,
                at: (resetVector + UInt32(offset)) & AddressTranslator.physicalAddressMask
            )
        }
        return machine
    }

    private func setRegisters(ax: UInt16, dx: UInt16, on machine: Machine) {
        _ = machine.cpu.execute(.movImmediateToRegister16(.ax, ax))
        _ = machine.cpu.execute(.movImmediateToRegister16(.dx, dx))
    }

    private func setStableFlags(on machine: Machine) -> UInt16 {
        for flag in [CPUFlag.carry, .parity, .auxiliaryCarry, .zero, .sign, .interruptEnable, .direction, .overflow] {
            _ = machine.cpu.execute(.setFlag(flag))
        }
        return machine.cpu.flags.rawValue
    }

    @Test("All eight IN/OUT encodings decode with the correct width and port source")
    func decoding() {
        let decoder = InstructionDecoder()

        var e4: [UInt8] = [0x12]
        #expect(decoder.decode(opcode: 0xE4, registers: RegisterFile()) { e4.removeFirst() } == .input(port: .immediate(0x12), isWord: false))
        var e5: [UInt8] = [0x34]
        #expect(decoder.decode(opcode: 0xE5, registers: RegisterFile()) { e5.removeFirst() } == .input(port: .immediate(0x34), isWord: true))
        var e6: [UInt8] = [0x56]
        #expect(decoder.decode(opcode: 0xE6, registers: RegisterFile()) { e6.removeFirst() } == .output(port: .immediate(0x56), isWord: false))
        var e7: [UInt8] = [0x78]
        #expect(decoder.decode(opcode: 0xE7, registers: RegisterFile()) { e7.removeFirst() } == .output(port: .immediate(0x78), isWord: true))

        let forbiddenReader: () -> UInt8 = {
            Issue.record("DX-port instruction requested an operand byte")
            return 0
        }
        #expect(decoder.decode(opcode: 0xEC, registers: RegisterFile(), nextByte: forbiddenReader) == .input(port: .dx, isWord: false))
        #expect(decoder.decode(opcode: 0xED, registers: RegisterFile(), nextByte: forbiddenReader) == .input(port: .dx, isWord: true))
        #expect(decoder.decode(opcode: 0xEE, registers: RegisterFile(), nextByte: forbiddenReader) == .output(port: .dx, isWord: false))
        #expect(decoder.decode(opcode: 0xEF, registers: RegisterFile(), nextByte: forbiddenReader) == .output(port: .dx, isWord: true))
    }

    @Test("Unmapped I/O reads return open-bus ones and writes are ignored")
    func unmappedPorts() {
        let bus = EmulatorBus(memory: Memory())

        #expect(bus.readIOByte(at: 0x1234) == 0xFF)
        #expect(bus.readIOWord(at: 0xFFFF) == 0xFFFF)
        bus.writeIOByte(0x12, at: 0x1234)
        bus.writeIOWord(0x3456, at: 0xFFFF)
        #expect(bus.readIOByte(at: 0x1234) == 0xFF)
        #expect(bus.readIOWord(at: 0xFFFF) == 0xFFFF)
    }

    @Test("Immediate-port IN zero-extends the port and isolates accumulator width")
    func immediateInput() {
        let byteMachine = machineWithOpcodes([0xE4, 0xFE])
        let byteDevice = SpyPortDevice()
        byteDevice.byteValue = 0x42
        byteMachine.bus.mapPortDevice(byteDevice, to: 0x00FE...0x00FE)
        setRegisters(ax: 0xAA00, dx: 0xFFFE, on: byteMachine)
        let byteFlags = setStableFlags(on: byteMachine)

        byteMachine.step()

        #expect(byteMachine.cpu.ax == 0xAA42)
        #expect(byteMachine.cpu.dx == 0xFFFE)
        #expect(byteMachine.cpu.flags.rawValue == byteFlags)
        #expect(byteMachine.cpu.ip == 2)
        #expect(byteMachine.cycleCount == 10)
        #expect(byteDevice.events == [.readByte(0x00FE)])

        let wordMachine = machineWithOpcodes([0xE5, 0x80])
        let wordDevice = SpyPortDevice()
        wordDevice.wordValue = 0xBEEF
        wordMachine.bus.mapPortDevice(wordDevice, to: 0x0080...0x0080)
        setRegisters(ax: 0x1234, dx: 0xAB80, on: wordMachine)
        let wordFlags = setStableFlags(on: wordMachine)

        wordMachine.step()

        #expect(wordMachine.cpu.ax == 0xBEEF)
        #expect(wordMachine.cpu.dx == 0xAB80)
        #expect(wordMachine.cpu.flags.rawValue == wordFlags)
        #expect(wordMachine.cycleCount == 10)
        #expect(wordDevice.events == [.readWord(0x0080)])
    }

    @Test("Immediate-port OUT transfers AL/AX without changing registers or flags")
    func immediateOutput() {
        let byteMachine = machineWithOpcodes([0xE6, 0x60])
        let byteDevice = SpyPortDevice()
        byteMachine.bus.mapPortDevice(byteDevice, to: 0x0060...0x0060)
        setRegisters(ax: 0xCAFE, dx: 0x1234, on: byteMachine)
        let byteFlags = setStableFlags(on: byteMachine)

        byteMachine.step()

        #expect(byteDevice.events == [.writeByte(0x0060, 0xFE)])
        #expect(byteMachine.cpu.ax == 0xCAFE)
        #expect(byteMachine.cpu.dx == 0x1234)
        #expect(byteMachine.cpu.flags.rawValue == byteFlags)
        #expect(byteMachine.cycleCount == 10)

        let wordMachine = machineWithOpcodes([0xE7, 0x61])
        let wordDevice = SpyPortDevice()
        wordMachine.bus.mapPortDevice(wordDevice, to: 0x0061...0x0061)
        setRegisters(ax: 0xCAFE, dx: 0x5678, on: wordMachine)
        let wordFlags = setStableFlags(on: wordMachine)

        wordMachine.step()

        #expect(wordDevice.events == [.writeWord(0x0061, 0xCAFE)])
        #expect(wordMachine.cpu.ax == 0xCAFE)
        #expect(wordMachine.cpu.dx == 0x5678)
        #expect(wordMachine.cpu.flags.rawValue == wordFlags)
        #expect(wordMachine.cycleCount == 10)
    }

    @Test("DX-port forms use the full 16-bit port and explicit word transfers")
    func dxPortForms() {
        let inputByte = machineWithOpcodes([0xEC])
        let inputByteDevice = SpyPortDevice()
        inputByteDevice.byteValue = 0x77
        inputByte.bus.mapPortDevice(inputByteDevice, to: 0xBEEF...0xBEEF)
        setRegisters(ax: 0xAA00, dx: 0xBEEF, on: inputByte)
        let inputByteFlags = setStableFlags(on: inputByte)
        inputByte.step()
        #expect(inputByte.cpu.ax == 0xAA77)
        #expect(inputByte.cpu.flags.rawValue == inputByteFlags)
        #expect(inputByteDevice.events == [.readByte(0xBEEF)])
        #expect(inputByte.cycleCount == 8)

        let inputWord = machineWithOpcodes([0xED])
        let inputWordDevice = SpyPortDevice()
        inputWordDevice.wordValue = 0x1357
        inputWord.bus.mapPortDevice(inputWordDevice, to: 0xBEEF...0xBEEF)
        setRegisters(ax: 0, dx: 0xBEEF, on: inputWord)
        let inputWordFlags = setStableFlags(on: inputWord)
        inputWord.step()
        #expect(inputWord.cpu.ax == 0x1357)
        #expect(inputWord.cpu.flags.rawValue == inputWordFlags)
        #expect(inputWordDevice.events == [.readWord(0xBEEF)])
        #expect(inputWord.cycleCount == 8)

        let outputByte = machineWithOpcodes([0xEE])
        let outputByteDevice = SpyPortDevice()
        outputByte.bus.mapPortDevice(outputByteDevice, to: 0xBEEF...0xBEEF)
        setRegisters(ax: 0x2468, dx: 0xBEEF, on: outputByte)
        let outputByteFlags = setStableFlags(on: outputByte)
        outputByte.step()
        #expect(outputByteDevice.events == [.writeByte(0xBEEF, 0x68)])
        #expect(outputByte.cpu.ax == 0x2468)
        #expect(outputByte.cpu.dx == 0xBEEF)
        #expect(outputByte.cpu.flags.rawValue == outputByteFlags)
        #expect(outputByte.cycleCount == 8)

        let outputWord = machineWithOpcodes([0xEF])
        let outputWordDevice = SpyPortDevice()
        outputWord.bus.mapPortDevice(outputWordDevice, to: 0xBEEF...0xBEEF)
        setRegisters(ax: 0x2468, dx: 0xBEEF, on: outputWord)
        let outputWordFlags = setStableFlags(on: outputWord)
        outputWord.step()
        #expect(outputWordDevice.events == [.writeWord(0xBEEF, 0x2468)])
        #expect(outputWord.cpu.ax == 0x2468)
        #expect(outputWord.cpu.dx == 0xBEEF)
        #expect(outputWord.cpu.flags.rawValue == outputWordFlags)
        #expect(outputWord.cycleCount == 8)
    }
}
