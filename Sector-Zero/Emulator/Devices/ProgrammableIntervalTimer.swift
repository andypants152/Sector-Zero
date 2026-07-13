enum PITAccessMode: UInt8, Equatable, Sendable {
    case lowByte = 1
    case highByte = 2
    case lowThenHigh = 3
}

enum PITMode: UInt8, Equatable, Sendable {
    case interruptOnTerminalCount = 0
    case rateGenerator = 2
    case squareWave = 3
}

struct PITChannelSnapshot: Equatable, Sendable {
    let accessMode: PITAccessMode
    let mode: PITMode
    let reloadValue: Int
    let currentCount: Int
    let output: Bool
    let gate: Bool
    let running: Bool
}

struct ProgrammableIntervalTimerSnapshot: Equatable, Sendable {
    let channels: [PITChannelSnapshot]
    let cpuClockRemainder: Int
    let channel2SpeakerEnabled: Bool
    let channel2SpeakerOutput: Bool
}

/// PC-compatible 8253 timer. The original PC derives one PIT input tick from
/// every four CPU clocks, so elapsed CPU clocks remain deterministic and need
/// no host-time conversion.
final class ProgrammableIntervalTimer: ClockedDevice, IOPortDevice {
    static let channel0Port: UInt16 = 0x40
    static let channel1Port: UInt16 = 0x41
    static let channel2Port: UInt16 = 0x42
    static let controlPort: UInt16 = 0x43
    static let cpuClocksPerInputTick = 4

    private struct Channel {
        var accessMode = PITAccessMode.lowThenHigh
        var mode = PITMode.interruptOnTerminalCount
        var reloadValue = 65_536
        var currentCount = 65_536
        var output = true
        var gate = true
        var running = false
        var pendingWriteLowByte: UInt8?
        var nextReadIsHigh = false
        var latchedCount: UInt16?
        var latchedReadIsHigh = false
        var squarePhaseTicks = 0

        var snapshot: PITChannelSnapshot {
            PITChannelSnapshot(
                accessMode: accessMode,
                mode: mode,
                reloadValue: reloadValue,
                currentCount: currentCount,
                output: output,
                gate: gate,
                running: running
            )
        }

        mutating func configure(access: PITAccessMode, mode: PITMode) {
            accessMode = access
            self.mode = mode
            pendingWriteLowByte = nil
            nextReadIsHigh = false
            latchedCount = nil
            latchedReadIsHigh = false
            running = false
            output = mode != .interruptOnTerminalCount
        }

        mutating func latchCount() {
            if latchedCount == nil {
                latchedCount = encodedCount
                latchedReadIsHigh = false
            }
        }

        mutating func write(_ value: UInt8) {
            switch accessMode {
            case .lowByte:
                load(rawValue: UInt16(value))
            case .highByte:
                load(rawValue: UInt16(value) << 8)
            case .lowThenHigh:
                if let low = pendingWriteLowByte {
                    pendingWriteLowByte = nil
                    load(rawValue: UInt16(low) | UInt16(value) << 8)
                } else {
                    pendingWriteLowByte = value
                }
            }
        }

        mutating func read() -> UInt8 {
            if let latchedCount {
                return readLatched(latchedCount)
            }
            return readValue(encodedCount, highPhase: &nextReadIsHigh)
        }

        mutating func setGate(_ high: Bool) {
            let wasHigh = gate
            gate = high
            guard wasHigh != high else { return }

            switch mode {
            case .interruptOnTerminalCount:
                running = high && currentCount > 0
            case .rateGenerator, .squareWave:
                if high {
                    restartPeriodicMode()
                } else {
                    running = false
                    output = true
                }
            }
        }

        /// Returns true when OUT changed during this input clock.
        mutating func tick() -> Bool {
            guard running, gate else { return false }
            let oldOutput = output

            switch mode {
            case .interruptOnTerminalCount:
                if currentCount > 1 {
                    currentCount -= 1
                } else {
                    currentCount = 0
                    output = true
                    running = false
                }
            case .rateGenerator:
                if !output {
                    output = true
                }
                if currentCount > 1 {
                    currentCount -= 1
                } else {
                    currentCount = reloadValue
                    output = false
                }
            case .squareWave:
                currentCount = currentCount > 1 ? currentCount - 1 : reloadValue
                squarePhaseTicks -= 1
                if squarePhaseTicks == 0 {
                    output.toggle()
                    squarePhaseTicks = output
                        ? (reloadValue + 1) / 2
                        : reloadValue / 2
                }
            }
            return output != oldOutput
        }

        private var encodedCount: UInt16 {
            UInt16(truncatingIfNeeded: currentCount == 65_536 ? 0 : currentCount)
        }

        private mutating func load(rawValue: UInt16) {
            reloadValue = rawValue == 0 ? 65_536 : Int(rawValue)
            currentCount = reloadValue
            latchedCount = nil
            nextReadIsHigh = false
            switch mode {
            case .interruptOnTerminalCount:
                output = false
                running = gate
            case .rateGenerator, .squareWave:
                restartPeriodicMode()
            }
        }

        private mutating func restartPeriodicMode() {
            currentCount = reloadValue
            output = true
            running = gate
            if mode == .squareWave {
                squarePhaseTicks = (reloadValue + 1) / 2
            }
        }

        private mutating func readLatched(_ value: UInt16) -> UInt8 {
            switch accessMode {
            case .lowByte:
                latchedCount = nil
                return UInt8(truncatingIfNeeded: value)
            case .highByte:
                latchedCount = nil
                return UInt8(value >> 8)
            case .lowThenHigh:
                if latchedReadIsHigh {
                    latchedCount = nil
                    latchedReadIsHigh = false
                    return UInt8(value >> 8)
                }
                latchedReadIsHigh = true
                return UInt8(truncatingIfNeeded: value)
            }
        }

        private func readValue(_ value: UInt16, highPhase: inout Bool) -> UInt8 {
            switch accessMode {
            case .lowByte:
                return UInt8(truncatingIfNeeded: value)
            case .highByte:
                return UInt8(value >> 8)
            case .lowThenHigh:
                defer { highPhase.toggle() }
                return highPhase ? UInt8(value >> 8) : UInt8(truncatingIfNeeded: value)
            }
        }
    }

    private let interruptController: ProgrammableInterruptController
    private var channels = [Channel(), Channel(), Channel()]
    private var cpuClockRemainder = 0
    private(set) var channel2SpeakerEnabled = false

    init(interruptController: ProgrammableInterruptController) {
        self.interruptController = interruptController
        channels[2].gate = false
    }

    var snapshot: ProgrammableIntervalTimerSnapshot {
        ProgrammableIntervalTimerSnapshot(
            channels: channels.map(\.snapshot),
            cpuClockRemainder: cpuClockRemainder,
            channel2SpeakerEnabled: channel2SpeakerEnabled,
            channel2SpeakerOutput: channel2SpeakerEnabled && channels[2].output
        )
    }

    func reset() {
        channels = [Channel(), Channel(), Channel()]
        channels[2].gate = false
        cpuClockRemainder = 0
        channel2SpeakerEnabled = false
        interruptController.lower(.timer)
    }

    func advance(by clocks: Int) {
        precondition(clocks >= 0, "PIT clock advance cannot be negative")
        let accumulated = cpuClockRemainder + clocks
        let ticks = accumulated / Self.cpuClocksPerInputTick
        cpuClockRemainder = accumulated % Self.cpuClocksPerInputTick
        guard ticks > 0 else { return }

        for _ in 0..<ticks {
            for index in channels.indices {
                let outputChanged = channels[index].tick()
                if index == 0, outputChanged {
                    if channels[index].output {
                        interruptController.raise(.timer)
                    } else {
                        interruptController.lower(.timer)
                    }
                }
            }
        }
    }

    func readByte(from port: UInt16) -> UInt8 {
        if let channel = channelIndex(for: port) {
            return channels[channel].read()
        }
        return 0xFF
    }

    func writeByte(_ value: UInt8, to port: UInt16) {
        if let channel = channelIndex(for: port) {
            channels[channel].write(value)
            if channel == 0 {
                // Programming mode 0 lowers OUT; periodic modes start high but
                // do not synthesize an IRQ edge until the first full period.
                interruptController.lower(.timer)
            }
            return
        }
        if port == Self.controlPort {
            writeControl(value)
        }
    }

    // The PC wires channel 2's gate, speaker enable, and output through the
    // PPI's port B/C (M45); these are the PPI-facing control points.

    func setChannel2Gate(_ enabled: Bool) {
        channels[2].setGate(enabled)
    }

    func setChannel2SpeakerEnabled(_ enabled: Bool) {
        channel2SpeakerEnabled = enabled
    }

    var channel2Output: Bool {
        channels[2].output
    }

    private func writeControl(_ value: UInt8) {
        let channelIndex = Int(value >> 6)
        guard channelIndex < channels.count else { return } // 8254 read-back is not on the 8253.
        let accessValue = (value >> 4) & 0x03
        if accessValue == 0 {
            channels[channelIndex].latchCount()
            return
        }
        guard let access = PITAccessMode(rawValue: accessValue) else { return }
        let encodedMode = (value >> 1) & 0x07
        let normalizedMode: UInt8 = switch encodedMode {
        case 6: 2
        case 7: 3
        default: encodedMode
        }
        guard let mode = PITMode(rawValue: normalizedMode) else { return }
        channels[channelIndex].configure(access: access, mode: mode)
        if channelIndex == 0 {
            interruptController.lower(.timer)
        }
    }

    private func channelIndex(for port: UInt16) -> Int? {
        guard (Self.channel0Port...Self.channel2Port).contains(port) else { return nil }
        return Int(port - Self.channel0Port)
    }
}
