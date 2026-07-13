# Sector Zero — CPU Core Roadmap & Handoff

Sector Zero is a SwiftUI + Metal macOS app emulating a clean, modern **Intel 8086
computer**. It is *not* a DOS emulator — DOS is merely one operating system that
may eventually boot on this virtual machine. The near-term focus is a trustworthy
CPU core, built in very small, individually reviewable milestones.

This document is a handoff brief so another contributor (human or AI) can take over.

---

## Handoff context (read first)

**Status:** M1 (authentic reset), M2 (instruction fetch), and M3 (instruction
decoder), M4 (execute NOP), and M5 (HLT + run-state) are complete and tested. The
next milestones are M6–M8 below.

**Architecture:** `Machine → CPU8086 → Bus → Memory → Devices`. The UI never touches
the core directly — it renders an immutable `MachineSnapshot` published by the
`@Observable` `SectorZeroWorkspace`; `workspace.step()` calls `Machine.step()` then
republishes the snapshot. Keep the emulator core free of any UI/observation concerns.

**Current CPU surface (`CPU8086`):** registers are `private(set)` (AX/BX/CX/DX,
SI/DI, SP/BP, CS/DS/ES/SS, IP), `flags: CPUFlags` (reset `0xF002`),
`lastFetchedOpcode: UInt8?`. Key methods:

- `reset()` — restores documented 8086 reset state (CS:IP = FFFF:0000 → physical
  FFFF0h; DS/ES/SS/IP cleared; FLAGS = `0xF002`; GP registers zeroed).
- `fetch() -> UInt8` — reads the opcode at CS:IP through the `Bus`, records it as
  `lastFetchedOpcode`, and advances IP with 16-bit wraparound.
- `dumpState()` — returns a `CPUStateSnapshot`.

`Machine.step()` performs a fetch only today. `Machine.snapshot()` bundles CPU state
+ cycle count + physical code address. Physical addressing lives in
`AddressTranslator.physicalAddress(segment:offset:)`.

**Cadence & guardrails (non-negotiable):**
- One small milestone at a time; **stop and report for review after each**.
- Every instruction/behavior gets unit tests *before* moving on. Correctness first.
- Value types where sensible; readable over clever; no god classes.
- Clean separation of responsibilities; the UI only communicates with the `Machine`
  (via the workspace snapshot).

**Test setup (there is a gotcha):** Swift Testing (`import Testing`, `@Test`,
`#expect`), `@testable import Sector_Zero`. Test files go in the **repo-root
`Sector-ZeroTests/` folder** — NOT nested inside `Sector-Zero/`. The `Sector-Zero/`
source folder is a filesystem-synchronized group and will sweep any `.swift` under it
into the app module, breaking the test build with "part of module 'Sector_Zero';
ignoring import" + "Unable to resolve module dependency: 'Testing'". New `.swift`
files in either synchronized folder are auto-included (no `.xcodeproj` edits needed).

Run tests:

```
xcodebuild test -project Sector-Zero.xcodeproj -scheme Sector-Zero -destination 'platform=macOS'
```

**Accuracy references:** Intel 8086 family manual (opcodes/timings); Ken Shirriff's
8086 silicon reverse-engineering posts; Wikipedia FLAGS-register and reset-vector
articles. Verify cycle counts against a documented 8086 timing table rather than
guessing.

---

## Completed

### M1 — Authentic 8086 reset ✅
Reset vector CS:IP = FFFF:0000 → physical FFFF0h. FLAGS resets to `0xF002` (all
condition/control flags clear; bits 1 and 12–15 hard-wired to 1 on the 8086).

### M2 — Instruction fetch ✅
`CPU8086.fetch()` reads one opcode at CS:IP through the `Bus`, records
`lastFetchedOpcode`, and advances IP (16-bit wrap). `Machine.step()` = fetch only;
`Machine.snapshot()` returns a value-type `MachineSnapshot`. The CPU inspector is now
value-driven and shows the fetched opcode (`OPC`); a STEP button drives fetches.

### M3 — Instruction decoder ✅
`InstructionDecoder.decode(opcode:nextByte:)` turns a fetched opcode into a typed
`Instruction` (`.nop` for 0x90, `.hlt` for 0xF4, `.unknown(byte)` otherwise) with no
execution and no state mutation. The `nextByte` closure is the fetch↔decode boundary
through which operand-bearing instructions will pull additional bytes later; nothing
decoded today invokes it (tests enforce this across all 256 opcodes).

---

## Next milestones

### M4 — Execute NOP (0x90) ✅
`Machine.step()` now runs fetch → decode → execute and charges the instruction's
clock cost via `ExecutionClock.advance(by:)`. `CPU8086.execute(_:)` returns each
instruction's cycle cost; NOP is 3 clocks and mutates nothing beyond the fetch's IP
advance. **Unknown-opcode policy: no-op-and-advance** at the same provisional
3-clock cost (never wedges; a trap can replace this once interrupts exist). HLT
decodes but is executed as a no-op until M5 gives it a run-state.

### M5 — HLT (0xF4) + CPU run-state ✅
`CPU8086.halted` is set by executing HLT (2 clocks); `Machine.step()` is a no-op
while halted (no fetch, no cycles) and `reset()` clears the state — reset is the
only exit until interrupt-driven wake-from-halt exists. `halted` is surfaced in
`CPUStateSnapshot` and the inspector (STATE row: RUN/HALT). `Machine.run(maxSteps:)`
steps until halt or the bound. A UI RUN control is still to be wired when the
workspace grows one.

### M6 — Register file with byte + word access
- **Goal:** Foundational operand storage — AX is AH:AL, etc. Nearly every future
  instruction needs both 8-bit and 16-bit register access.
- **Build:** A `RegisterFile` exposing word registers (AX,BX,CX,DX,SI,DI,SP,BP) and
  their byte halves (AL/AH, BL/BH, CL/CH, DL/DH) with correct high/low mapping.
  Refactor `CPU8086` to back its GP registers with it. Consider `Register8` /
  `Register16` operand enums for the decoder to use later.
- **Don't:** Add new instructions (this is internal machinery).
- **Tests:** writing AL/AH composes AX correctly and vice-versa (for BX/CX/DX too);
  word writes don't disturb unrelated registers; reset zeroes all; byte↔word
  round-trip invariants.

### M7 — MOV immediate → register (0xB0–0xBF)
- **Goal:** First data movement; exercises immediate-operand fetch and register
  writes end-to-end.
- **Build:** Decode `0xB0–0xB7` (MOV reg8, imm8) and `0xB8–0xBF` (MOV reg16, imm16),
  fetching the 1- or 2-byte immediate from the stream (little-endian for imm16),
  writing via the M6 register file. Extend `Instruction` with a
  `.movImmediateToRegister` case carrying target register + value. Add documented
  cycles (**~4 clocks**, register — verify). IP advances past opcode + immediate.
- **Don't:** Implement ModR/M (register/memory MOVs) — that's M8.
- **Tests:** `B0 42` → AL=0x42; `BB 34 12` → BX=0x1234 (endianness!); IP advances by
  instruction length; flags untouched (MOV affects no flags); all 16 register
  encodings map correctly.

### M8 — ModR/M byte decoding + effective address
- **Goal:** The reusable operand-addressing machinery that unlocks most of the
  instruction set (MOV r/m, ADD, SUB, CMP, …).
- **Build:** A clean ModR/M decoder: extract `mod`, `reg`, `r/m`; resolve register
  operands and all memory addressing modes; fetch displacement bytes (8/16-bit) per
  `mod`; compute the effective address and its default segment (BP-based modes
  default to SS). Represent results as a value type (e.g.
  `Operand.register(...)` / `Operand.memory(segment:offset:)`). Keep it a standalone,
  heavily-tested unit.
- **Don't:** Implement the arithmetic/logic instructions that consume it yet — just
  decode + address calculation. Segment-override prefixes can be a follow-up.
- **Tests:** table-driven across every `mod`/`r/m` combination — register direct
  (mod=11), memory forms with 0/8/16-bit displacement, the direct-address special
  case (mod=00, r/m=110), and BP defaulting to SS. Assert computed effective address
  and consumed instruction length for known byte sequences.

---

## Beyond M8

The natural continuation: MOV using ModR/M → ADD/SUB/CMP with flag updates →
conditional jumps → stack ops (PUSH/POP/CALL/RET) → interrupts → BIOS → boot sector.
The long arc from the project charter stays intact:

```
CPU → Memory → Interrupts → Devices → BIOS → Boot sector → MS-DOS 4.0
```

Do not attempt to boot anything until the CPU core is trustworthy.
