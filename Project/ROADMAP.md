# Sector Zero — CPU Core Roadmap & Handoff

Sector Zero is a SwiftUI + Metal macOS app emulating a clean, modern **Intel 8086
computer**. It is *not* a DOS emulator — DOS is merely one operating system that
may eventually boot on this virtual machine. The near-term focus is a trustworthy
CPU core, built in very small, individually reviewable milestones.

This document is a handoff brief so another contributor (human or AI) can take over.

---

## Handoff context (read first)

**Status:** M1 (authentic reset), M2 (instruction fetch), and M3 (instruction
decoder), M4 (execute NOP), M5 (HLT + run-state), M6 (register file), M7
(MOV immediate → register), M8 (ModR/M decoding), M9 (MOV r/m ↔ reg), and M10
(ALU flag engine + ADD) are complete and tested. The next milestones are M11–M14
below.

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

### M6 — Register file with byte + word access ✅
`RegisterFile` (a value type) stores the eight GP word registers with subscript
access by `Register16` or `Register8`; the byte enums use the 8086 `reg` encoding
order (AX,CX,DX,BX,SP,BP,SI,DI / AL,CL,DL,BL,AH,CH,DH,BH) so the decoder can map
encodings directly later. `CPU8086` GP registers are now computed views over the
file. No new instructions.

### M7 — MOV immediate → register (0xB0–0xBF) ✅
Decoder maps `0xB0–0xB7` → `.movImmediateToRegister8` and `0xB8–0xBF` →
`.movImmediateToRegister16`, pulling the immediate through `nextByte`
(little-endian for imm16); the low three opcode bits index the register enums
directly. Execution writes through the register file, affects no flags, and costs
4 clocks. All 16 encodings are covered by tests, including IP advancing by full
instruction length. ModR/M forms are deliberately absent — that's M8.

### M8 — ModR/M byte decoding + effective address ✅
`ModRMDecoder.decode(modRMByte:registers:nextByte:)` is a pure, standalone unit
returning a value-type `ModRM` (raw `mod`/`reg` fields + a resolved
`ModRMOperand`: `.register(encoding)` or `.memory(EffectiveAddress)` with the
displacement folded in and the default segment recorded — SS for BP-based modes,
DS otherwise). Handles all mod=00/01/10/11 forms, sign-extended disp8,
little-endian disp16, the mod=00 r/m=110 direct-address special case, and 16-bit
EA wraparound. Table-driven tests cover every mod/r/m combination and consumed
length. Nothing consumes it yet; segment-override prefixes remain a follow-up.

---

## Next six milestones

### M9 — MOV r/m ↔ reg (0x88–0x8B) ✅
All four directions decode through `ModRMDecoder` (now wired into
`InstructionDecoder`, whose `decode` takes the register file for EA resolution)
and execute through new CPU memory-operand helpers: physical address = actual
segment value (DS, or SS for BP modes) via `AddressTranslator`; word access is
little-endian with 16-bit offset wrap. Cycles: reg→reg 2, reg→mem 9+EA,
mem→reg 8+EA, with the full documented EA-clock table carried on `ModRM`.
`CPU8086.writeSegment(_:to:)` exists for tests and future `8E`/POP sreg.
Still out: segment-override prefixes, `8C`/`8E`, `C6`/`C7`.

### M10 — ALU flag engine + ADD (0x00–0x03) ✅
Pure `ALU.add8/add16` return `(result, ArithmeticFlags)`; the CPU applies them
via `CPUFlags.applyArithmetic`, leaving TF/IF/DF alone. Flag semantics: CF carry
out, AF carry out of bit 3, ZF/SF from result, PF even parity of the low byte
only, OF signed overflow. `00`–`03` decode into generic `.aluRegisterToRM*` /
`.aluRMToRegister*` cases carrying an `ALUBinaryOp` (just `.add` today — SUB/CMP
extend the same enum in M11), executed through shared operand read/write
helpers. Cycles: reg↔reg 3, mem→reg 9+EA, reg→mem 16+EA (read-modify-write).

### M11 — SUB and CMP (0x28–0x2B, 0x38–0x3B)
- **Goal:** Subtraction flags plus the first instruction that only sets flags —
  the gateway to conditional jumps.
- **Build:** `ALU.subtract` (CF = borrow; AF = borrow into bit 3; OF = signed
  overflow of minuend−subtrahend; ZF/SF/PF as usual). `28`–`2B` write the
  result; `38`–`3B` (CMP) compute identically but **discard the result**,
  updating only flags. Same ModR/M plumbing and timings as ADD.
- **Don't:** SBB; NEG; immediate forms (`2C`/`2D`, `3C`/`3D`, `80`–`83`).
- **Tests:** borrow vectors (0x00−1: CF SF PF AF set; 0x80−1 byte: OF set);
  equal-operands CMP sets ZF and writes nothing; CMP leaves both operands and
  memory untouched; SUB writes to registers and memory correctly.

### M12 — Conditional jumps (0x70–0x7F) + JMP short (0xEB)
- **Goal:** Control flow; the CPU can finally loop and branch on M10/M11 flags.
- **Build:** Decode a signed 8-bit displacement (relative to the *next*
  instruction, i.e. applied after IP passed the operand). Implement all sixteen
  Jcc opcodes — JO/JNO, JB/JNB, JZ/JNZ, JBE/JNBE, JS/JNS, JP/JNP, JL/JNL,
  JLE/JNLE — as flag predicates over `CPUFlags` (JL/JLE use SF≠OF), plus
  unconditional `EB`. Cycles: **16** taken / **4** not taken; JMP short **15** —
  verify against the timing table.
- **Don't:** Near/far JMP with 16-bit or absolute operands; LOOP/JCXZ.
- **Tests:** each predicate against hand-set flag states (both taken and not);
  backward displacement (a CMP/JNZ countdown loop actually terminates);
  forward skip over an instruction; IP wraparound on branch; cycle split
  between taken/not-taken.

### M13 — Stack: PUSH/POP reg (0x50–0x5F)
- **Goal:** The stack discipline (SS:SP, decrement-before-write) that CALL/RET
  and interrupts will build on.
- **Build:** CPU stack helpers `push16`/`pop16`: PUSH decrements SP by 2 then
  writes the word at SS:SP; POP reads then increments. Decode/execute
  `50`–`57` (PUSH reg16) and `58`–`5F` (POP reg16) — the low three bits are the
  register encoding, as with MOV-immediate. Cycles: PUSH **11**, POP **8** —
  verify. Note the 8086 `PUSH SP` quirk (pushes the *already-decremented* SP);
  match it and pin it with a test.
- **Don't:** PUSH/POP of segment registers or r/m forms; PUSHF/POPF; any
  stack-overflow detection.
- **Tests:** PUSH writes at SS:SP−2 with SP updated (seed SS non-zero);
  POP round-trips; LIFO order over several registers; SP wraparound at 0;
  the PUSH SP quirk; flags untouched.

### M14 — CALL/RET near (0xE8, 0xC3)
- **Goal:** Subroutines — enough machinery to run real structured programs
  within one code segment.
- **Build:** `E8` CALL near-relative: fetch a 16-bit displacement, push the
  return IP (address of the next instruction), then IP += disp (16-bit wrap).
  `C3` RET near: pop IP. Reuses M13's stack helpers unchanged. Cycles: CALL
  **19**, RET **16** — verify. After this, write the first end-to-end program
  test: a called subroutine that computes something, returns, and HLTs.
- **Don't:** Far CALL/RET (`9A`/`CB`), RET imm16 (`C2`), CALL r/m (`FF /2`).
- **Tests:** CALL pushes the correct return address and lands at the target
  (forward and backward); RET resumes after the CALL; nested calls unwind in
  order; the end-to-end program leaves the expected register state and halt.

---

## Beyond M14

The natural continuation: immediate ALU forms (`80`–`83`) → INC/DEC → LOOP/JCXZ →
segment-override prefixes → PUSHF/POPF + remaining stack forms → INT/IRET and the
interrupt vector table → devices → BIOS → boot sector. The long arc from the
project charter stays intact:

```
CPU → Memory → Interrupts → Devices → BIOS → Boot sector → MS-DOS 2.0 → MS-DOS 4.0
```

MS-DOS 2.0 boots first as a stepping stone: it's MIT-licensed like 4.0, needs far
less of the machine to come up, and its source is small enough to read alongside a
debugger when boot goes wrong. 4.0 (also MIT, so bundleable in an App Store build)
remains the shipping target.

Do not attempt to boot anything until the CPU core is trustworthy.
