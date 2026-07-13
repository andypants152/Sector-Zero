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
(MOV immediate → register), M8 (ModR/M decoding), M9 (MOV r/m ↔ reg), M10
(ALU flag engine + ADD), M11 (SUB/CMP), M12 (conditional jumps), M13
(PUSH/POP), M14 (CALL/RET near), M15 (immediate ALU forms), and M16
(INC/DEC reg16) are complete and tested. The next milestone is M17 below.

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

### M11 — SUB and CMP (0x28–0x2B, 0x38–0x3B) ✅
`ALU.subtract8/16` (CF = borrow, AF = borrow into bit 3, OF = signed overflow of
minuend−subtrahend). `.sub` and `.cmp` extend `ALUBinaryOp`; CMP computes
identically but `writesResult == false`, so nothing is written and its memory
r/m-destination form costs 9+EA rather than SUB's read-modify-write 16+EA. The
decoder's three ALU opcode blocks share one path keyed on opcode bits 5–3.

### M12 — Conditional jumps (0x70–0x7F) + JMP short (0xEB) ✅
`JumpCondition` maps the opcode's low nibble to the eight base predicates
(OF, CF, ZF, CF∨ZF, SF, PF, SF≠OF, ZF∨(SF≠OF)), with the low bit negating.
Displacement is a signed disp8 applied after IP has passed the operand, with
16-bit wrap. Cycles: 16 taken / 4 not taken; JMP short 15. Tested via a full
predicate table, taken/not-taken cycle splits, a CMP/SUB+JNZ countdown loop,
forward skips, and backward-wrap. Near/far 16-bit JMPs and LOOP/JCXZ deferred.

### M13 — Stack: PUSH/POP reg (0x50–0x5F) ✅
`push16`/`pop16` stack helpers (SS:SP, decrement-then-write / read-then-
increment, 16-bit wrap) plus PUSH reg16 (11 clocks) and POP reg16 (8 clocks).
The 8086 `PUSH SP` quirk is matched — the register is read *after* SP moves,
storing the decremented value — and pinned by a test that initially caught the
286-style behavior. LIFO order, SS-vs-DS separation, SP wrap at 0, and
flag preservation are all covered. PUSHF/POPF, sreg and r/m forms deferred.

### M14 — CALL/RET near (0xE8, 0xC3) ✅
`E8` fetches a little-endian signed disp16; IP already points past it, so
that value is the return address — pushed via M13's `push16`, then
IP += disp with 16-bit wrap. `C3` pops IP. Cycles: CALL 19, RET 16. Flags
untouched. Tested: forward/backward-wrap targets, return-address contents on
the stack, nested calls unwinding in order, flag preservation, and the first
end-to-end program (CALL a subroutine that ADDs, RET, HLT). Far CALL/RET
(`9A`/`CB`), RET imm16 (`C2`), and CALL r/m (`FF /2`) deferred.

### M15 — Immediate ALU forms (0x80, 0x81, 0x83) ✅
The group decodes through `ModRMDecoder`; the ModR/M reg field selects the
op (/0 ADD, /5 SUB, /7 CMP — the group's other five ops consume their bytes
and no-op-and-advance until implemented). `80` imm8, `81` little-endian
imm16, `83` sign-extended imm8 → 16-bit. Execution reuses the M10/M11 ALU
and operand helpers. Cycles: reg 4, mem 17+EA, CMP mem 10+EA. Tested per
op × reg/mem × width, `83` sign extension both directions, flag parity with
register forms, and full IP advance. `82` (undocumented alias) left unknown.
Lesson pinned: decoder tests must feed streams as long as the longest
decode (a 2-byte stream trapped once `81` pulled 5 bytes).

### M16 — INC/DEC reg16 (0x40–0x4F) ✅
`40`–`47` INC, `48`–`4F` DEC; the low three bits index the register.
Executed as ALU add/subtract of 1 through a new
`CPUFlags.applyArithmeticPreservingCarry` (OF/SF/ZF/AF/PF update, CF
untouched — the 8086 quirk; `applyArithmetic` now composes on top of it).
3 clocks. Tested: all 16 encodings, 0xFFFF→0 and 0→0xFFFF wraps with CF
unchanged (both CF states), 0x7FFF→0x8000 / 0x8000→0x7FFF signed overflow,
AF, and a DEC+JNZ countdown loop. `FE`/`FF` r/m forms deferred.

### M17 — LOOP family + JCXZ (0xE0–0xE3)
- **Goal:** Hardware loop instructions — completes the countdown-loop idiom
  with the real 8086 primitives.
- **Build:** `E2` LOOP: CX -= 1 (no flags), branch on CX ≠ 0. `E1` LOOPE/Z
  and `E0` LOOPNE/NZ additionally require ZF set/clear. `E3` JCXZ branches
  when CX == 0 without touching it. All take a signed disp8 relative to the
  next instruction. Cycles (taken/not): LOOP 17/5, LOOPE 18/6, LOOPNE 19/5,
  JCXZ 18/6 — verify.
- **Don't:** Near/far 16-bit JMPs (`E9`/`EA`); string-op REP prefixes.
- **Tests:** LOOP countdown leaves CX 0 and flags untouched, each variant's
  ZF gate, JCXZ taken/not-taken, cycle splits, CX=0 entry runs 65536 times
  (or pin the wrap semantics with a cheaper equivalent).

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
