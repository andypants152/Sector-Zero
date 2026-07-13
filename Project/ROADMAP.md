# Sector Zero — CPU Core Roadmap & Handoff

Sector Zero is a SwiftUI + Metal macOS app emulating a clean, modern **Intel 8086
computer**. It is *not* a DOS emulator — DOS is merely one operating system that
may eventually boot on this virtual machine. The near-term focus is a trustworthy
CPU core, built in very small, individually reviewable milestones.

This document is a handoff brief so another contributor (human or AI) can take over.

---

## Handoff context (read first)

**Status:** M1–M16 are complete and tested (reset, fetch, decode, execute loop;
register file; ModR/M; MOV forms; ADD/SUB/CMP incl. immediates; conditional
jumps; PUSH/POP; CALL/RET near; INC/DEC). The next milestone is M17 below.

**Architecture:** `Machine → CPU8086 → Bus → Memory → Devices`. The UI never touches
the core directly — it renders an immutable `MachineSnapshot` published by the
`@Observable` `SectorZeroWorkspace`; `workspace.step()` calls `Machine.step()` then
republishes the snapshot. Keep the emulator core free of any UI/observation concerns.

**Current CPU surface (`CPU8086`):** registers live in a `RegisterFile` value type
(word or byte-half access; `private(set)` computed views AX/BX/CX/DX, SI/DI, SP/BP),
plus CS/DS/ES/SS, IP, `flags: CPUFlags` (reset `0xF002`), `halted`,
`lastFetchedOpcode: UInt8?`. Key methods:

- `reset()` — documented 8086 reset state (CS:IP = FFFF:0000 → physical FFFF0h;
  DS/ES/SS/IP cleared; FLAGS = `0xF002`; GP registers zeroed; halt cleared).
- `fetch() -> UInt8` — reads at CS:IP through the `Bus`, records
  `lastFetchedOpcode`, advances IP with 16-bit wrap.
- `execute(_ instruction:) -> Int` — mutates state, returns the clock cost.
- `writeSegment(_:to:)` — segment-register writes (tests and future `8E`/POP sreg).
- `dumpState()` — returns a `CPUStateSnapshot`.

`Machine.step()` runs fetch → decode → execute and charges cycles via
`ExecutionClock`; it is a no-op while halted. `Machine.run(maxSteps:)` steps until
halt or the bound. `Machine.snapshot()` bundles CPU state + cycle count + physical
code address. Physical addressing lives in
`AddressTranslator.physicalAddress(segment:offset:)`. Decoding is pure
(`InstructionDecoder` + `ModRMDecoder`, pulling operand bytes through a `nextByte`
closure); arithmetic is pure (`ALU` returning `(result, ArithmeticFlags)`).

**Established policies:**
- **Unknown opcodes:** no-op-and-advance at a provisional 3 clocks (never wedges;
  a trap can replace this once interrupts exist). Unimplemented ops *inside* a
  decoded ModR/M group still consume their full instruction so IP stays aligned.
- **Flags:** `applyArithmetic` (all six) vs. `applyArithmeticPreservingCarry`
  (INC/DEC). Control flags TF/IF/DF are never touched by arithmetic.
- **Cycle counts** come from the documented 8086 timing table (EA clocks carried
  on `ModRM`) — verify against a table, never guess.

**Cadence & guardrails (non-negotiable):**
- One small milestone at a time; **stop and report for review after each**.
- Every instruction/behavior gets unit tests *before* moving on. Correctness first.
- Value types where sensible; readable over clever; no god classes.
- Clean separation of responsibilities; the UI only communicates with the `Machine`
  (via the workspace snapshot).

**Test setup (there are gotchas):** Swift Testing (`import Testing`, `@Test`,
`#expect`), `@testable import Sector_Zero`. Test files go in the **repo-root
`Sector-ZeroTests/` folder** — NOT nested inside `Sector-Zero/`. The `Sector-Zero/`
source folder is a filesystem-synchronized group and will sweep any `.swift` under it
into the app module, breaking the test build with "part of module 'Sector_Zero';
ignoring import" + "Unable to resolve module dependency: 'Testing'". New `.swift`
files in either synchronized folder are auto-included (no `.xcodeproj` edits needed).
Also: decoder tests that feed fixed byte streams must supply as many bytes as the
*longest* decode can pull (currently 5: `81` mod=00 r/m=110) — a drained stream's
`removeFirst()` traps and takes the whole suite down with it (the test host is the
app itself, so the crash report looks like an app crash).

Run tests:

```
xcodebuild test -project Sector-Zero.xcodeproj -scheme Sector-Zero -destination 'platform=macOS'
```

**Accuracy references:** Intel 8086 family manual (opcodes/timings); Ken Shirriff's
8086 silicon reverse-engineering posts; Wikipedia FLAGS-register and reset-vector
articles.

---

## Completed (M1–M16)

### M1 — Authentic 8086 reset ✅
Reset vector CS:IP = FFFF:0000 → physical FFFF0h. FLAGS resets to `0xF002` (all
condition/control flags clear; bits 1 and 12–15 hard-wired to 1 on the 8086).

### M2 — Instruction fetch ✅
`CPU8086.fetch()` reads one opcode at CS:IP through the `Bus`, records
`lastFetchedOpcode`, and advances IP (16-bit wrap). `Machine.snapshot()` returns a
value-type `MachineSnapshot`; the CPU inspector is value-driven and shows the
fetched opcode (`OPC`); a STEP button drives fetches.

### M3 — Instruction decoder ✅
`InstructionDecoder.decode` turns a fetched opcode into a typed `Instruction` with
no execution and no state mutation. The `nextByte` closure is the fetch↔decode
boundary through which operand-bearing instructions pull additional bytes.

### M4 — Execute NOP (0x90) ✅
`Machine.step()` runs fetch → decode → execute and charges the instruction's
clock cost via `ExecutionClock.advance(by:)`. NOP is 3 clocks. **Unknown-opcode
policy: no-op-and-advance** at the same provisional 3-clock cost.

### M5 — HLT (0xF4) + CPU run-state ✅
`CPU8086.halted` set by HLT (2 clocks); `Machine.step()` is a no-op while halted
(no fetch, no cycles); `reset()` is the only exit until interrupts exist. Surfaced
in the inspector (STATE row: RUN/HALT). `Machine.run(maxSteps:)` steps until halt
or the bound. A UI RUN control is still to be wired.

### M6 — Register file with byte + word access ✅
`RegisterFile` (a value type) stores the eight GP word registers with subscript
access by `Register16` or `Register8`; the enums use the 8086 `reg` encoding order
(AX,CX,DX,BX,SP,BP,SI,DI / AL,CL,DL,BL,AH,CH,DH,BH) so the decoder maps encodings
directly. `CPU8086` GP registers are computed views over the file.

### M7 — MOV immediate → register (0xB0–0xBF) ✅
`B0`–`B7` imm8, `B8`–`BF` little-endian imm16; low three opcode bits index the
register enums. No flags; 4 clocks. All 16 encodings tested, including IP
advancing by full instruction length.

### M8 — ModR/M byte decoding + effective address ✅
`ModRMDecoder.decode` is a pure, standalone unit returning a value-type `ModRM`
(raw `mod`/`reg` fields + a resolved `ModRMOperand`: `.register(encoding)` or
`.memory(EffectiveAddress)` with displacement folded in and the default segment
recorded — SS for BP-based modes, DS otherwise). Handles all mod forms,
sign-extended disp8, little-endian disp16, the mod=00 r/m=110 direct-address
special case, and 16-bit EA wraparound. The documented EA-clock table is carried
on `ModRM`.

### M9 — MOV r/m ↔ reg (0x88–0x8B) ✅
All four directions through `ModRMDecoder` (wired into `InstructionDecoder`,
whose `decode` takes the register file for EA resolution); CPU memory-operand
helpers translate through the actual segment value; word access is little-endian
with 16-bit offset wrap. Cycles: reg→reg 2, reg→mem 9+EA, mem→reg 8+EA.

### M10 — ALU flag engine + ADD (0x00–0x03) ✅
Pure `ALU.add8/add16` return `(result, ArithmeticFlags)`; applied via
`CPUFlags.applyArithmetic`, leaving TF/IF/DF alone. CF carry out, AF carry out of
bit 3, ZF/SF from result, PF even parity of the low byte only, OF signed overflow.
Generic `.aluRegisterToRM*` / `.aluRMToRegister*` cases carry an `ALUBinaryOp`.
Cycles: reg↔reg 3, mem→reg 9+EA, reg→mem 16+EA (read-modify-write).

### M11 — SUB and CMP (0x28–0x2B, 0x38–0x3B) ✅
`ALU.subtract8/16` (CF = borrow, AF = borrow into bit 3, OF = signed overflow).
CMP computes like SUB but `writesResult == false`; its memory-destination form
costs 9+EA rather than 16+EA. The decoder's ALU opcode blocks share one path
keyed on opcode bits 5–3.

### M12 — Conditional jumps (0x70–0x7F) + JMP short (0xEB) ✅
`JumpCondition` maps the low nibble to the eight base predicates (OF, CF, ZF,
CF∨ZF, SF, PF, SF≠OF, ZF∨(SF≠OF)); the low bit negates. Signed disp8 applied
after IP passes the operand, 16-bit wrap. Cycles: 16 taken / 4 not; JMP short 15.

### M13 — Stack: PUSH/POP reg (0x50–0x5F) ✅
`push16`/`pop16` helpers (SS:SP, decrement-then-write / read-then-increment,
16-bit wrap); PUSH 11 clocks, POP 8. The 8086 `PUSH SP` quirk is matched (the
register is read *after* SP moves) and pinned by a test.

### M14 — CALL/RET near (0xE8, 0xC3) ✅
`E8` pushes the return IP (IP already past the disp16) then IP += disp with wrap;
`C3` pops IP. CALL 19, RET 16. Tested through nested calls and the first
end-to-end program (CALL a subroutine that ADDs, RET, HLT).

### M15 — Immediate ALU forms (0x80, 0x81, 0x83) ✅
ModR/M reg field selects the op (/0 ADD, /5 SUB, /7 CMP; the group's other five
ops consume their bytes and no-op-and-advance until implemented). `80` imm8,
`81` imm16, `83` sign-extended imm8 → 16-bit. Cycles: reg 4, mem 17+EA, CMP mem
10+EA. `82` (undocumented alias) left unknown.

### M16 — INC/DEC reg16 (0x40–0x4F) ✅
ALU add/subtract of 1 through `CPUFlags.applyArithmeticPreservingCarry`
(OF/SF/ZF/AF/PF update, CF untouched — the 8086 quirk; `applyArithmetic`
composes on top of it). 3 clocks. `FE`/`FF` r/m forms deferred.

---

## Next ten milestones (M17–M26)

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
  ZF gate, JCXZ taken/not-taken, cycle splits, CX=0 entry wraps to 65536
  iterations (pin the wrap semantics with a cheap equivalent).

### M18 — JMP near and far (0xE9, 0xEA)
- **Goal:** Unconditional 16-bit jumps, including the first cross-segment
  control transfer (the reset vector itself is a far-jump target in real BIOSes).
- **Build:** `E9` JMP near: signed disp16 relative to the next instruction,
  16-bit wrap. `EA` JMP far: little-endian offset then segment; load IP and CS
  atomically. Cycles: near 15, far 15 — verify.
- **Don't:** JMP r/m (`FF /4`, `FF /5`).
- **Tests:** near forward/backward/wrap; far jump lands at the new CS:IP and
  the physical fetch address reflects both; a far jump back into a low segment
  from the reset segment (the classic BIOS handoff shape).

### M19 — Logical ALU: AND/OR/XOR (0x08–0x0B, 0x20–0x23, 0x30–0x33)
- **Goal:** The bitwise half of the ALU, reusing the M10/M11 machinery.
- **Build:** Extend `ALUBinaryOp` with `.and`/`.or`/`.xor` and add pure
  `ALU.and/or/xor` (8/16). Flag rule for logicals: **CF = OF = 0**, ZF/SF/PF
  from the result, AF undefined (leave it cleared and note it). Wire the three
  r/m↔reg opcode blocks through the existing shared decoder path, and enable
  /1 OR, /4 AND, /6 XOR in the `80`/`81`/`83` immediate group. Same cycle
  table as ADD.
- **Don't:** TEST and NOT (different shapes — M20/M25); accumulator-immediate
  shortcut forms (M20).
- **Tests:** truth-table spot checks per op/width, CF/OF forced set then
  cleared by a logical, immediate-group parity with register forms, XOR
  reg,reg as the idiomatic zeroing (ZF set).

### M20 — TEST + accumulator-immediate shortcuts (0x84/0x85, 0xA8/0xA9, 0x04/0x05, 0x0C/0x0D, 0x24/0x25, 0x2C/0x2D, 0x34/0x35, 0x3C/0x3D)
- **Goal:** TEST (AND that only sets flags) and the one-byte-shorter
  accumulator-immediate forms real assemblers emit constantly.
- **Build:** `84`/`85` TEST r/m,reg (computes AND, `writesResult == false`,
  9 clocks reg / 10+EA mem — verify). `A8`/`A9` TEST AL/AX,imm (4 clocks).
  The `04`–`3D` accumulator forms decode straight to the existing ALU cases
  with AL/AX as destination and an immediate source (4 clocks) — pure decoder
  work, no new execution paths.
- **Don't:** TEST in the `F6`/`F7` group (M25).
- **Tests:** TEST leaves both operands untouched, flag parity between `3C`
  (CMP AL,imm) and the `80 /7` long form, every accumulator opcode decodes to
  the right op/width, cycle counts.

### M21 — XCHG + remaining MOV forms (0x86/0x87, 0x91–0x97, 0xA0–0xA3, 0xC6/0xC7)
- **Goal:** Round out data movement so compiled/assembled code stops hitting
  unknown opcodes in its inner loops.
- **Build:** `86`/`87` XCHG r/m↔reg (reg↔reg 4 clocks, mem 17+EA; no flags);
  `91`–`97` XCHG AX,reg one-byte forms (3 clocks; note `90` = XCHG AX,AX is
  already NOP). `A0`–`A3` MOV AL/AX ↔ direct-address moffs16 (10 clocks).
  `C6`/`C7` MOV r/m,imm (reg 4, mem 10+EA; ModR/M reg field must be /0).
- **Don't:** Segment-register MOVs (M22); LEA/LDS/LES.
- **Tests:** XCHG swaps without flag changes (both directions, mem and reg),
  moffs uses DS and little-endian, `C7` to memory with displacement + imm16
  consumes the full byte stream (the M15 stream-length lesson applies — this
  becomes the new longest decode at 6 bytes).

### M22 — Segment registers: MOV sreg, PUSH/POP sreg, override prefixes (0x8C/0x8E, 0x06–0x1F evens, 0x26/0x2E/0x36/0x3E)
- **Goal:** Real segmented addressing — programs can finally set up their own
  DS/ES/SS instead of tests poking `writeSegment`.
- **Build:** `8C`/`8E` MOV r/m16 ↔ sreg (the ModR/M reg field indexes
  ES/CS/SS/DS; writing CS via `8E` is technically possible on the 8086 —
  match it but flag it in a comment). PUSH/POP sreg (`06`/`0E`/`16`/`1E`
  push ES/CS/SS/DS; `07`/`17`/`1F` pop ES/SS/DS; `0F` POP CS is the 8086's
  infamous encoding — decode it as POP CS like real silicon). Segment-override
  prefixes `26`/`2E`/`36`/`3E` set a pending override consumed by the next
  instruction's EA resolution (prefix costs 2 clocks; the decode loop must
  treat prefixes as part of one instruction — no interrupt window between).
- **Don't:** LDS/LES; multiple-prefix edge cases beyond last-one-wins.
- **Tests:** MOV to/from each sreg, PUSH/POP round-trips, an override
  redirecting a BP-based (SS-default) access to DS and vice versa, override +
  ModR/M + displacement byte-stream length, POP SS/interrupt-shadow noted as
  deferred.

### M23 — Flag manipulation: PUSHF/POPF, LAHF/SAHF, CLC/STC/CMC, CLI/STI, CLD/STD (0x9C/0x9D, 0x9E/0x9F, 0xF5/0xF8/0xF9, 0xFA/0xFB, 0xFC/0xFD)
- **Goal:** Direct FLAGS access — prerequisite for IRET, context switching,
  and the BIOS idiom of returning flags to callers.
- **Build:** `9C` PUSHF (10 clocks) / `9D` POPF (8) via the stack helpers;
  POPF must respect `CPUFlags`' hard-wired reserved bits. `9F` LAHF copies
  SF/ZF/AF/PF/CF into AH (bit layout 7,6,4,2,0 with bits 5,3 = 0, bit 1 = 1);
  `9E` SAHF writes them back (4 clocks each). One-byte flag sets/clears:
  CMC/CLC/STC (`F5`/`F8`/`F9`), CLI/STI (`FA`/`FB`), CLD/STD (`FC`/`FD`) —
  2 clocks each. IF/DF now become meaningful state to preserve.
- **Don't:** Acting on IF (no interrupts yet) or DF (no string ops yet) —
  just store them faithfully.
- **Tests:** PUSHF/POPF round-trip preserves everything incl. reserved bits,
  LAHF/SAHF bit layout exactly, each set/clear/complement, POPF cannot clear
  reserved bits.

### M24 — ADC and SBB (0x10–0x13, 0x18–0x1B, group /2 and /3)
- **Goal:** Carry-chained arithmetic — multi-word adds/subtracts, the last
  binary ALU ops.
- **Build:** `ALU.addWithCarry8/16` and `subtractWithBorrow8/16` (fold the
  incoming CF into the operation; flag semantics match ADD/SUB including AF
  across the carry). Extend `ALUBinaryOp` with `.adc`/`.sbb`; wire the two
  r/m↔reg blocks and enable /2 ADC, /3 SBB in the immediate group. Same
  cycle table as ADD.
- **Don't:** Accumulator-immediate shortcut forms if M20's pattern doesn't
  make them free (they should be — `14`/`15`, `1C`/`1D`).
- **Tests:** 32-bit add/sub composed from two 16-bit ops (the canonical use),
  CF-in of both states per op, AF/OF edge cases, immediate-group parity.

### M25 — Shifts and rotates (0xD0–0xD3)
- **Goal:** The shift/rotate group — heavily used for multiplication by
  powers of two, masking, and bit twiddling.
- **Build:** ModR/M reg field selects: /0 ROL, /1 ROR, /2 RCL, /3 RCR,
  /4 SHL/SAL, /5 SHR, /7 SAR. `D0`/`D1` shift by 1; `D2`/`D3` by CL (mod
  nothing — the 8086 does not mask the count; a CL of 255 really loops).
  Flags: CF = last bit shifted out; OF defined only for count 1 (per-op
  rules); SF/ZF/PF from the result for shifts, unchanged for rotates; AF
  undefined. Cycles: by-1 reg 2, by-1 mem 15+EA; by-CL reg 8+4/bit, mem
  20+EA+4/bit.
- **Don't:** The 186+ `C0`/`C1` imm8 forms (not on the 8086).
- **Tests:** each op ×widths for count 1 (incl. OF rules), CL-count loops
  with per-bit cycle cost, CF capture on both ends, rotate-through-carry
  9/17-bit behavior, memory read-modify-write.

### M26 — Group F6/F7: NOT, NEG, TEST imm, MUL/IMUL/DIV/IDIV
- **Goal:** The unary group — completes the 8086 arithmetic set.
- **Build:** ModR/M reg selects: /0 TEST r/m,imm (reuses M20 flag path),
  /2 NOT (no flags), /3 NEG (SUB from zero; CF set unless operand was 0),
  /4 MUL (AX = AL×r/m8, DX:AX = AX×r/m16; CF/OF set when the high half is
  nonzero), /5 IMUL (signed), /6 DIV, /7 IDIV (quotient/remainder into
  AL/AH or AX/DX). Divide-by-zero should raise the not-yet-implemented INT 0
  path — until interrupts exist, halt with a documented sentinel and a TODO.
- **Don't:** Exact multi-cycle timing fidelity (MUL/DIV timings vary by
  operand; use the documented ranges' documented typical values and note it).
- **Tests:** NOT/NEG including NEG 0 and NEG 0x80/0x8000 (OF set, value
  unchanged), MUL/IMUL sign and high-half flag behavior, DIV/IDIV
  quotient/remainder signs, divide-by-zero sentinel, TEST imm parity with
  `A8`/`84`.

---

## Beyond M26

Remaining CPU work, roughly in order: the `FE`/`FF` INC/DEC/CALL/JMP/PUSH r/m
group → far CALL/RET (`9A`/`CB`) + RET imm16 (`C2`/`CA`) → string ops
(MOVS/CMPS/SCAS/LODS/STOS) with REP/REPE/REPNE prefixes and DF → LEA/LDS/LES →
INT/INTO/IRET and the interrupt vector table (retiring both the unknown-opcode
no-op policy and the M26 divide-by-zero sentinel) → wake-from-halt → decimal
adjust (DAA/DAS/AAA/AAS/AAM/AAD) → CBW/CWD, WAIT/LOCK/ESC stubs. Then the
machine grows outward:

```
CPU → Memory → Interrupts → Devices → BIOS → Boot sector → MS-DOS 2.0 → MS-DOS 4.0
```

MS-DOS 2.0 boots first as a stepping stone: it's MIT-licensed like 4.0, needs far
less of the machine to come up, and its source is small enough to read alongside a
debugger when boot goes wrong. 4.0 (also MIT, so bundleable in an App Store build)
remains the shipping target.

Do not attempt to boot anything until the CPU core is trustworthy.
