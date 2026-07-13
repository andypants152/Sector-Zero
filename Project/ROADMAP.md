# Sector Zero — CPU Core Roadmap & Handoff

Sector Zero is a SwiftUI + Metal macOS app emulating a clean, modern **Intel 8086
computer**. It is *not* a DOS emulator — DOS is merely one operating system that
may eventually boot on this virtual machine. The near-term focus is a trustworthy
CPU core, built in very small, individually reviewable milestones.

This document is a handoff brief so another contributor (human or AI) can take over.

---

## Handoff context (read first)

**Status:** M1–M47 are complete and tested (reset, fetch, decode, execute loop;
register file; ModR/M; MOV forms incl. r/m,imm, moffs, and sreg; XCHG;
ADD/ADC/SBB/SUB/CMP incl. immediates; AND/OR/XOR; TEST + accumulator forms;
conditional jumps; PUSH/POP incl. sreg; CALL/RET near; INC/DEC; LOOP/JCXZ;
JMP near/far; segment overrides; direct FLAGS access and manipulation;
shifts/rotates; unary arithmetic incl. multiply/divide; r/m INC/DEC/PUSH/POP;
indirect near CALL/JMP; far CALL/JMP and immediate/far RET; LEA/LDS/LES;
MOVS/LODS/STOS; CMPS/SCAS; REP/REPE/REPNE; software interrupts and IRET;
CPU-generated, NMI, and maskable interrupt delivery; decimal and ASCII adjust;
sign extension and XLAT; port I/O and IN/OUT; LOCK/WAIT/ESC and opcode-table
completion policy; deterministic device scheduling and run/pause slices; PC
physical memory map, protected system ROM, and project firmware loading; master
8259A interrupt routing, masking, priority, and EOI; deterministic 8253 timer,
IRQ0, and channel-2 speaker gate; CGA 80×25 text VRAM, CRTC state, and snapshot-
driven CRT rendering; XT keyboard scan-code delivery through the 8255/PIC;
8237A floppy-channel DMA with page wrapping, terminal count, masking, and cycle
accounting; and a 765-compatible read-only floppy path with project media
mount/eject). The next milestone is M48 below.

**Prefixes:** a pending `CPU8086.segmentOverride` redirects the next
instruction's *data-operand* segment. `Machine.step()` consumes segment, repeat,
and LOCK prefixes in one loop (2 clocks each; last segment/repeat wins), then
decodes+executes+clears. REP execution is centralized in
`CPU8086.executeRepeated`; `Machine` preserves a suspended repeat context when
an interrupt is accepted between iterations and resumes it after IRET without
redoing completed work. **All
memory-operand access must route through `resolved(_:)`** (the operand
read/write helpers and moffs do; stack/code accesses deliberately don't). New
memory-touching instructions (string ops, PUSH/POP m16) must honor it too.

**Architecture:** `Machine → CPU8086 → Bus → Memory → Devices`. The UI never touches
the core directly — it renders an immutable `MachineSnapshot` published by the
`@Observable` `SectorZeroWorkspace`; `workspace.step()` calls `Machine.step()` then
republishes the snapshot. Keep the emulator core free of any UI/observation concerns.

**Current CPU surface (`CPU8086`):** registers live in a `RegisterFile` value type
(word or byte-half access; `private(set)` computed views AX/BX/CX/DX, SI/DI, SP/BP),
plus CS/DS/ES/SS, IP, `flags: CPUFlags` (reset `0xF002`), `halted`, and
`lastFetchedOpcode: UInt8?`. Key methods:

- `reset()` — documented 8086 reset state (CS:IP = FFFF:0000 → physical FFFF0h;
  DS/ES/SS/IP cleared; FLAGS = `0xF002`; GP registers zeroed; halt/fault cleared).
- `fetch() -> UInt8` — reads at CS:IP through the `Bus`, records
  `lastFetchedOpcode`, advances IP with 16-bit wrap.
- `execute(_ instruction:) -> Int` — mutates state, returns the clock cost.
- `writeSegment(_:to:)` — segment-register writes (tests and future `8E`/POP sreg).
- `dumpState()` — returns a `CPUStateSnapshot`.

`Machine.step()` first arbitrates pending interrupts, then runs fetch → decode →
execute and charges cycles via `ExecutionClock`; while halted it accepts only a
wakeable NMI or enabled INTR. `Machine.run(maxSteps:)` steps until a non-wakeable
halt or the bound. `Machine.snapshot()` bundles CPU state + cycle count + physical
code address. Physical addressing lives in
`AddressTranslator.physicalAddress(segment:offset:)`. Decoding is pure
(`InstructionDecoder` + `ModRMDecoder`, pulling operand bytes through a `nextByte`
closure); arithmetic is pure (`ALU` returning `(result, ArithmeticFlags)`).
Software and machine-level interrupts share `CPU8086.enterInterrupt`, which
builds the real-mode FLAGS/CS/IP frame and reads CS:IP from the physical IVT.

**Established policies:**
- **Unknown opcodes:** no-op-and-advance at a provisional 3 clocks (never wedges;
  a trap can replace this once interrupts exist). Unimplemented ops *inside* a
  decoded ModR/M group still consume their full instruction so IP stays aligned.
- **Flags:** `applyArithmetic` (all six) vs. `applyArithmeticPreservingCarry`
  (INC/DEC). Control flags TF/IF/DF are never touched by arithmetic.
- **Divide errors:** DIV/IDIV preserve operands on zero-divisor or quotient
  overflow and enter vector 0 with the original 8086's following-IP return
  semantics (not the restartable fault semantics of later x86 generations).
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

## Completed (M17–M22)

### M17 — LOOP family + JCXZ (0xE0–0xE3) ✅
`LoopCondition` carries the ZF gate (E0 LOOPNE, E1 LOOPE, E2 unconditional)
and each variant's taken/not-taken clocks (19/5, 18/6, 17/5). CX decrements
unconditionally, without flags, and the branch tests the *new* CX — so CX=0
entry wraps to 0xFFFF and loops 65536 times (pinned by a single-step wrap
test). `E3` JCXZ (18/6) branches on CX == 0 without modifying it. Tested:
countdown loops, flag transparency, both ZF gates each way, cycle splits,
JCXZ taken/not-taken. Test-writing note: accumulator-immediate CMP (`3C`)
doesn't exist until M20 — use `80 /7` in fixtures.

### M18 — JMP near and far (0xE9, 0xEA) ✅
`E9` JMP near: signed disp16 relative to the next instruction, 16-bit wrap.
`EA` JMP far: little-endian offset then segment, loaded into IP and CS
together (the first CS-changing instruction; `cs = segment` directly in
`execute`). Both 15 clocks, no flags touched. Tested: near
forward/backward/wrap, far load of CS:IP with the physical fetch address
reflecting both, execution continuing at the far target, and the BIOS
handoff shape (far jump from the reset segment down to low memory).

---

### M19 — Logical ALU: AND/OR/XOR (0x08–0x0B, 0x20–0x23, 0x30–0x33) ✅
`ALUBinaryOp` gains `.and`/`.or`/`.xor`; pure `ALU.and/or/xor` (8/16) share
a `logicalFlags8/16` helper: **CF = OF = 0**, ZF/SF/PF from the result, AF
cleared deterministically (undefined on real silicon). The three r/m↔reg
blocks join the existing shared decoder path (op selector by `opcode >> 3`),
and /1 OR, /4 AND, /6 XOR are enabled in the `80`/`81`/`83` immediate group.
No execution changes beyond `perform8/16` — cycle table matches ADD. Tested:
per-op truth tables, XOR reg,reg zeroing, a logical clearing set CF/OF/AF,
immediate-group parity with register forms, and a memory destination.
Note: the opcode-formatting fetch test moved off `step()` onto a bare
`fetch()` now that low opcodes like `0A` pull operands.

### M20 — TEST + accumulator-immediate shortcuts ✅
`ALUBinaryOp` gains `.test` (AND with `writesResult == false`) and a shared
`init?(aluSelector:)` that maps the 3-bit op selector — now the single source
of truth for all three ALU decode sites (r/m↔reg blocks, the 80/81/83 group,
and the accumulator forms). `84`/`85` TEST r/m,reg reuse the ALU
register-to-r/m path (3 reg / **9+EA** mem — the roadmap's earlier "9/10+EA"
note was wrong; verified against the timing table). `A8`/`A9` TEST AL/AX,imm
and the `04`–`3D` accumulator forms decode to `aluImmediateToRM8/16` with
`.register(0)` as destination (4 clocks) — pure decoder work, no new
execution. The accumulator mask case (`opcode & 0xC6 == 0x04`) consumes its
immediate even for the still-unimplemented ADC/SBB (`14/15`, `1C/1D`) so IP
stays aligned; those decode to `.unknown` until M24. Tested: TEST leaves both
operands untouched (byte/word/imm), `3C` vs `80 /7` flag parity, every
implemented accumulator op, cycle counts, and ADC/SBB still-unknown.

### M21 — XCHG + remaining MOV forms ✅
`86`/`87` XCHG r/m↔reg (swap via a temp; reg↔reg 4, mem 17+EA, no flags);
`91`–`97` XCHG AX,reg one-byte forms (3 clocks; `90` stays NOP). `A0`–`A3`
MOV AL/AX ↔ direct-address moffs, modeled as one `movMemoryOffset` case with
`isWord`/`store` flags, flat 10 clocks, DS-relative. `C6`/`C7` MOV r/m,imm
(new `movImmediateToRM8/16`; reg 4, mem 10+EA); bytes are consumed before the
ModR/M-reg-field-/0 check so non-/0 encodings stay aligned before decoding to
`.unknown`. `C7` to a direct address is the new longest decode (5 operand
bytes); the deterministic-decode test stream grew to 6 for headroom. Tested:
XCHG all forms flag-free, moffs each direction + DS addressing + little-endian,
MOV r/m,imm reg/mem with full IP advance, and the reg≠0 unknown path.

### M22 — Segment registers: MOV sreg, PUSH/POP sreg, override prefixes (0x8C/0x8E, 0x06–0x1F evens, 0x26/0x2E/0x36/0x3E) ✅
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

---

## Completed (M23–M26)

### M23 — Flag manipulation: PUSHF/POPF, LAHF/SAHF, CLC/STC/CMC, CLI/STI, CLD/STD (0x9C/0x9D, 0x9E/0x9F, 0xF5/0xF8/0xF9, 0xFA/0xFB, 0xFC/0xFD) ✅
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

### M24 — ADC and SBB (0x10–0x13, 0x18–0x1B, group /2 and /3) ✅
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

### M25 — Shifts and rotates (0xD0–0xD3) ✅
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
  9/17-bit behavior, memory read-modify-write. Undefined AF and multibit OF
  are preserved deterministically.

### M26 — Group F6/F7: NOT, NEG, TEST imm, MUL/IMUL/DIV/IDIV ✅
- **Goal:** The unary group — completes the 8086 arithmetic set.
- **Build:** ModR/M reg selects: /0 TEST r/m,imm (reuses M20 flag path),
  /2 NOT (no flags), /3 NEG (SUB from zero; CF set unless operand was 0),
  /4 MUL (AX = AL×r/m8, DX:AX = AX×r/m16; CF/OF set when the high half is
  nonzero), /5 IMUL (signed), /6 DIV, /7 IDIV (quotient/remainder into
  AL/AH or AX/DX). Divide-by-zero and quotient overflow originally used a
  temporary `CPUFault.divideError` halt sentinel; M35 replaced it with vector 0
  delivery. The original 8086 also faults when IDIV would produce the
  most-negative byte/word quotient.
- **Don't:** Exact multi-cycle timing fidelity (MUL/DIV timings vary by
  operand; use the rounded midpoint of each documented range and note it).
- **Tests:** NOT/NEG including NEG 0 and NEG 0x80/0x8000 (OF set, value
  unchanged), MUL/IMUL sign and high-half flag behavior, DIV/IDIV
  quotient/remainder signs, divide-error operand preservation, TEST imm parity with
  `A8`/`84`.

---

## CPU completion (M27–M39)

These milestones finish the documented 8086 integer surface before peripheral
work begins. Keep each milestone independently shippable; an opcode-coverage
matrix introduced in M39 is the CPU-completion gate.

### M27 — Remaining r/m stack and INC/DEC forms (0x8F, 0xFE, 0xFF /0, /1, /6) ✅
- **Goal:** Remove the last register-only restrictions from basic stack and
  unary operations.
- **Build:** `FE /0` and `/1` INC/DEC r/m8; `FF /0` and `/1` INC/DEC r/m16;
  `FF /6` PUSH r/m16; `8F /0` POP r/m16. Reuse the established operand helpers
  so segment overrides affect the data operand while stack traffic remains
  SS-relative. Preserve CF for INC/DEC. Consume the complete instruction before
  rejecting unsupported group selectors.
- **Don't:** Add the `FF` control-transfer selectors yet.
- **Tests:** Register and memory forms at both widths, CF preservation, BP-based
  default segment plus override, SP wrap, the 8086 PUSH-SP value quirk, POP into
  SP, and nonmatching group selectors staying byte-aligned.

### M28 — Indirect near CALL/JMP (0xFF /2, /4) ✅
- **Goal:** Allow procedure pointers and jump tables within the current code
  segment.
- **Build:** `FF /2` CALL near absolute r/m16 pushes the post-decode IP, then
  loads IP; `FF /4` JMP near absolute r/m16 loads IP without touching CS.
  Resolve the source value before mutating SP or IP.
- **Don't:** Treat these as relative displacements; add far pointers; change
  flags.
- **Tests:** Register and memory targets, return-address correctness through
  `RET`, target and stack wrap, segment override on a memory pointer, and exact
  clocks including EA cost.

### M29 — Far CALL/JMP and immediate RET (0x9A, 0xCA–0xCB, 0xC2, 0xFF /3, /5) ✅
- **Goal:** Complete inter-segment procedure and indirect transfer support.
- **Build:** Direct far CALL (`9A`), indirect far CALL/JMP through m16:16
  (`FF /3`, `/5`), RET near imm16 (`C2`), RET far (`CB`), and RET far imm16
  (`CA`). Far CALL pushes CS and return IP in the architecturally correct order;
  far RET restores IP then CS. The RET immediate adjusts SP after popping.
- **Don't:** Permit register operands for m16:16 selectors; implement task or
  privilege semantics from later x86 chips.
- **Tests:** Direct and indirect round-trips, stack word order, caller argument
  cleanup, offset/segment reads across a 16-bit offset wrap, segment override on
  pointer reads, invalid register forms, and flags unchanged.

### M30 — Address and far-pointer loads: LEA/LDS/LES (0x8D, 0xC4–0xC5) ✅
- **Goal:** Support compiler-generated address calculation and far data
  pointers.
- **Build:** LEA writes the decoded effective offset without reading memory;
  LDS/LES read m16:16 and update the GP destination plus DS/ES. Make the ModR/M
  model expose an effective offset separately from its resolved segment.
- **Don't:** Accept register ModR/M operands; apply a segment override to LEA
  (there is no data read).
- **Tests:** Every addressing family, displacement wrap, no-read LEA using a
  spying bus, little-endian far pointers, segment override for LDS/LES, and
  atomic destination updates.

### M31 — String data movement: MOVS/LODS/STOS (0xA4–0xA5, 0xAA–0xAD) ✅
- **Goal:** Establish one-iteration string semantics and make DF operational.
- **Build:** Byte/word MOVS, LODS, and STOS. Source is DS:SI (subject to segment
  override); destination is always ES:DI and never overridden. Advance or
  retreat SI/DI by the operand width according to DF, with 16-bit wrap.
- **Don't:** Add REP or compare strings; let a prefix redirect ES:DI.
- **Tests:** Both widths and DF directions, SI/DI wrap, source override,
  destination fixed to ES, little-endian word transfer, flags unchanged, and
  documented single-iteration clocks.

### M32 — String comparison: CMPS/SCAS (0xA6–0xA7, 0xAE–0xAF) ✅
- **Goal:** Complete the one-iteration string instruction family.
- **Build:** CMPS computes source minus destination and advances SI+DI; SCAS
  computes AL/AX minus ES:DI and advances DI. Reuse SUB flag generation.
- **Don't:** Write either compared value; add repeat behavior.
- **Tests:** Equality/borrow/overflow flag cases, byte and word forms, both DF
  directions, source override only for CMPS, offset wrap, and operand order.

### M33 — REP/REPE/REPNE prefixes (0xF2–0xF3) ✅
- **Goal:** Run counted string operations with authentic CX and ZF gates.
- **Build:** Extend the prefix loop so segment and repeat prefixes compose, last
  repeat prefix wins, and the entire prefixed instruction remains one
  `Machine.step()` for now. REP repeats MOVS/LODS/STOS while CX is nonzero;
  REPE/REPNE repeat CMPS/SCAS while CX is nonzero and the post-iteration ZF gate
  holds. CX=0 performs no data access. Charge setup plus per-iteration clocks.
  Structure execution so an interrupt boundary can be inserted between
  iterations without redesigning the decoded instruction.
- **Don't:** Give REP meaning on unrelated opcodes beyond consuming the prefix;
  implement 186+ aliases.
- **Tests:** Zero/one/many iterations, early compare exit both ways, DF, CX and
  address wrap, mixed/repeated prefixes with last-one-wins, segment override
  composition, and cycle totals.

### M34 — Software interrupts and IRET (0xCC–0xCF) ✅
- **Goal:** Establish one reusable real-mode interrupt-entry mechanism.
- **Build:** INT3, INT imm8, INTO, and IRET. Interrupt entry reads the vector
  from physical `0000:(type×4)`, pushes FLAGS then CS then return IP, clears
  TF/IF, and loads CS:IP. IRET pops IP, CS, then FLAGS through `CPUFlags` so
  reserved bits remain correct. INTO does nothing when OF is clear.
- **Don't:** Add external interrupt lines, protected-mode semantics, or replace
  unsupported opcodes with a fictional invalid-opcode interrupt (the 8086 has no
  `#UD`).
- **Tests:** Exact stack frame and order, IVT little-endian layout, nested INT
  and IRET, INT3 return IP, both INTO paths, SP wrap, and reserved FLAGS bits.

### M35 — CPU-generated and external interrupts, shadows, HLT wake ✅
- **Goal:** Make interrupts a machine-level event rather than only an opcode.
- **Build:** Route divide errors from M26 through vector 0; deliver trap vector 1
  after an instruction when TF is set; add NMI and maskable INTR inputs with
  instruction-boundary arbitration. NMI ignores IF; INTR requires IF. Implement
  the one-instruction inhibition after STI and MOV/POP SS, allow accepted
  interrupts to wake HLT, and make REP resumable between iterations without
  repeating completed work. Preserve original-8086 return semantics: divide
  error is recognized after DIV/IDIV and saves the following IP, unlike the
  restartable fault semantics of later x86 generations.
- **Don't:** Add a PIC yet; the tests drive interrupt lines directly.
- **Tests:** Priority and masking, the 8086 divide-error return IP, trap return IP,
  STI/SS shadows, HLT remaining asleep without an accepted interrupt, NMI wake,
  interrupt and resume midway through REP, and nested IRET recovery.

### M36 — Decimal and ASCII adjust (0x27, 0x2F, 0x37, 0x3F, 0xD4–0xD5) ✅
- **Goal:** Cover the 8086's BCD/ASCII arithmetic used by early software.
- **Build:** DAA, DAS, AAA, AAS, AAM, and AAD with explicit per-instruction flag
  rules. AAM's encoded base byte must be consumed (normally 10); a zero base
  raises divide error through M35.
- **Don't:** Generalize behavior from later processors where undocumented flags
  differ; guess undefined flag values—choose and document a deterministic policy.
- **Tests:** Intel examples, all AF/CF input combinations for DAA/DAS, carry and
  no-carry AAA/AAS, non-decimal AAM/AAD bases, base-zero fault, and unchanged or
  deterministic undefined flags.
- **Completed policy:** Architecturally undefined flags are preserved. AAA/AAS
  use the original 8086's separate AL correction and AH increment/decrement,
  including the edge behavior that differs from later processors. AAM/AAD
  consume and use the encoded base byte; AAM base zero enters vector 0 with AX
  intact and the following IP in the interrupt frame. Timings are 4 clocks for
  DAA/DAS/AAA/AAS, 83 for AAM, and 60 for AAD.

### M37 — Sign extension, XLAT, and translation helpers (0x98–0x99, 0xD7) ✅
- **Goal:** Finish the small but common data-conversion instructions.
- **Build:** CBW sign-extends AL into AX; CWD sign-extends AX into DX:AX; XLAT
  loads AL from DS:[BX+unsigned AL], subject to segment override. No flags.
- **Don't:** Add 386-size variants.
- **Tests:** Positive/negative/boundary values, XLAT address wrap and segment
  override, flags untouched, and exact clocks.
- **Completed:** CBW sign-extends AL into AH in 2 clocks; CWD sign-extends AX
  into DX in 5 clocks. XLAT adds unsigned AL to BX with 16-bit offset wrap,
  reads through the override-aware DS data path, and costs 11 clocks. All three
  leave FLAGS unchanged.

### M38 — Port I/O bus and IN/OUT (0xE4–0xE7, 0xEC–0xEF) ✅
- **Goal:** Create the CPU↔device boundary required by PC-compatible hardware.
- **Build:** Add a 16-bit I/O-port space beside memory on `Bus`, with explicit
  byte/word reads and writes. Implement immediate-port and DX-port IN/OUT for
  AL/AX. Define unmapped reads/writes deterministically and keep device lookup
  out of `CPU8086`.
- **Don't:** Memory-map I/O or introduce concrete peripherals.
- **Tests:** All eight encodings, immediate-port zero extension, full 16-bit DX
  ports, word transfers through a spy port device, unmapped behavior,
  flags/register isolation, and clocks.
- **Completed:** `EmulatorBus` owns a non-overlapping UInt16 port map and routes
  explicit byte/word transfers to `IOPortDevice`; unmapped reads return FFh or
  FFFFh and writes are ignored. All immediate and DX forms preserve FLAGS and
  non-destination registers. Immediate ports cost 10 clocks and DX ports 8.

### M39 — LOCK/WAIT/ESC policy and CPU completion gate (0x9B, 0xD8–0xDF, 0xF0) ✅
- **Goal:** Close the opcode table deliberately and declare the integer core
  ready for machine work.
- **Build:** WAIT observes a stub coprocessor-ready signal; ESC consumes its
  ModR/M/displacement and delegates to a no-coprocessor stub; LOCK participates
  in the prefix loop and marks valid memory read-modify-write operations atomic
  at the bus boundary. Add a generated or table-driven 256-opcode coverage test
  classifying every encoding as implemented, intentionally aliased/reserved, or
  explicitly unsupported. Replace silent provisional unknown handling with an
  observable emulator fault for unsupported implementation gaps while retaining
  documented 8086 alias/reserved behavior.
- **Don't:** Emulate an 8087; invent an invalid-opcode CPU exception.
- **Tests:** Prefix composition, legal/illegal LOCK use, WAIT ready/not-ready,
  ESC byte consumption for every ModR/M length, no accidental unknown opcodes in
  the supported matrix, and representative end-to-end CPU diagnostics.
- **Completed:** WAIT holds fetch on a mutable coprocessor-ready bus signal; all
  eight ESC opcodes consume complete ModR/M addressing and call a deterministic
  no-coprocessor endpoint. LOCK composes with existing prefixes, rejects
  non-memory-RMW uses with an emulator diagnostic, and brackets legal operations
  with bus-level atomic markers. The 256-byte table classifies 233 implemented
  primary bytes and 23 intentional 8086 reserved/undocumented-alias slots, with
  no unsupported documented primary opcodes. Unknown and invalid group forms now
  stop with an observable `CPUFault` after consuming their complete encoding.

---

## Machine and boot path (M40–M50)

**Compatibility target:** define Sector Zero as an IBM-PC-compatible real-mode
machine built around the existing 8086 core. It need not reproduce 8088 bus
timing, but its memory map, I/O ports, interrupts, BIOS contracts, and disk/video
behavior must be compatible enough for unmodified PC DOS applications. Intentional
deviations and deferred behavior are recorded in [`MACHINE_PROFILE.md`](MACHINE_PROFILE.md).

### M40 — Deterministic machine scheduler + run/pause ✅
- **Goal:** Turn instruction clock counts into the timebase that drives devices
  without coupling them to the UI.
- **Build:** `Machine.step()` reports elapsed clocks to clocked devices; add a
  bounded run slice with pause/cancel control; publish one immutable snapshot per
  slice rather than per cycle. Wire the existing UI RUN control through the
  workspace and keep execution off the main actor.
- **Don't:** Promise wall-clock accuracy or add a device thread per peripheral.
- **Tests:** Deterministic device tick totals, halt/interrupt behavior, run bound,
  pause latency, reset, and snapshot consistency; UI tests for RUN/PAUSE state.
- **Completed:** `Machine.step()` reports elapsed clocks and routes every clock
  batch to attached `ClockedDevice`s. `runSlice` is instruction-bounded, samples
  pause at each boundary, terminates cleanly for HLT, WAIT, and faults, and
  returns one consistent immutable snapshot plus an explicit stop reason. The
  workspace runs 2,048-instruction slices on a dedicated execution queue,
  publishes one snapshot per slice on the main actor, and exposes responsive
  RUN/PAUSE state while disabling STEP. Host speed-cap waits poll pause state in
  bounded intervals so throttling cannot hold PAUSE until the end of a long
  wall-clock sleep. Scheduler and workspace tests cover
  device totals, interrupt wakeup, bounds, pause, reset, and UI-facing state.

### M41 — PC memory map, ROM regions, and firmware loading ✅
- **Goal:** Replace flat writable RAM with a bus-owned address map suitable for
  firmware and adapters.
- **Build:** Map conventional RAM, reserved adapter space, and read-only system
  ROM including the reset vector. Support deterministic ROM images in tests and
  project-configured firmware in the app. Preserve 20-bit physical wrap.
- **Don't:** Put mapping policy in `Memory`; silently allow writes to ROM.
- **Tests:** Region boundaries, ROM write protection, reset-vector fetch, word
  access across region and 1 MiB boundaries, overlap rejection, and snapshots.
- **Completed:** `EmulatorBus` owns a wrapping 20-bit map with 640 KiB
  conventional RAM, open adapter space at A0000h–EFFFFh, and protected 64 KiB
  system ROM at F0000h–FFFFFh. Guest ROM writes are rejected with an observable
  diagnostic; host image loading remains explicit for tests and configuration.
  Firmware images from 1–64 KiB are validated and top-aligned over the reset
  vector. Project packages now include a firmware folder and optional relative
  or absolute firmware path, loaded and snapshotted when the app opens a
  machine. Region metadata, ROM size, and write diagnostics are part of
  `MachineSnapshot`; run slices stop and the workspace surfaces rejected guest
  writes without inventing a CPU exception. Word writes retain 8086 byte-cycle
  ordering at protection boundaries, so an allowed byte can commit even when
  its ROM-side partner is rejected.
- **Compatibility watch:** Real PCs ignore ROM writes; if firmware or DOS-era
  memory probes hit this diagnostic, demote it from a run stop to passive state.

### M42 — 8259A-compatible programmable interrupt controller ✅
- **Goal:** Multiplex hardware IRQs onto the CPU's INTR input.
- **Build:** Model the master PIC's initialization words, mask register, request/
  in-service state, priority, acknowledge/vector delivery, and EOI through its
  standard ports. Devices raise/lower named IRQ lines through `Machine`/`Bus`.
- **Don't:** Add a cascaded second PIC until software requires IRQ8–15.
- **Tests:** Initialization, masks, fixed priority, simultaneous IRQs, EOI,
  level transitions, IF interaction, and HLT wake.
- **Completed:** The bus installs a master PIC at ports 20h/21h with ICW1–4
  initialization, OCW1 masking, OCW2 specific/non-specific EOI, and OCW3 IRR/
  ISR selection. It tracks eight named IRQ lines, fixed IRQ0-first priority,
  request and in-service registers, higher-priority preemption, edge-triggered
  transitions by default, optional level-triggered reassertion, and auto-EOI.
  `Machine` acknowledges PIC vectors only when IF and interrupt shadows allow,
  wakes HLT for deliverable requests, resets PIC state with the machine, and
  publishes controller state in `MachineSnapshot`. The direct-vector INTR hook
  remains available for CPU-focused tests and specialist callers. Focused tests
  cover initialization and ports, masks, simultaneous priority, ISR blocking,
  EOI, edge/level transitions, IF gating, snapshots, and HLT wake.

### M43 — 8253-compatible timer and channel-2 speaker gate ✅
- **Goal:** Provide BIOS timekeeping and the periodic IRQ0 source.
- **Build:** Implement the PIT control/data ports and the counter modes required
  by BIOS/DOS, clocked deterministically from M40. Channel 0 raises IRQ0 through
  the PIC; expose channel 2 plus its gate/output as state for a later audio sink.
- **Don't:** Generate host audio yet or tie timer progress to display refresh.
- **Tests:** Programming/latching, divisor-zero semantics, periodic IRQ cadence,
  mask/EOI interaction, channel-2 gate, and long-run determinism.
- **Completed:** The bus installs a three-channel PIT at ports 40h–43h and a
  minimal PC speaker-control endpoint at 61h. It implements binary modes 0, 2,
  and 3, low/high/paired access, stable count latching, the 65,536 interpretation
  of a zero divisor, gate-driven periodic restart, and mode-accurate output
  transitions. One PIT input tick is accumulated for every four emulated CPU
  clocks, independent of host time or scheduler batch size. Channel 0 drives
  PIC IRQ0 with mask/in-service/EOI behavior supplied by M42; channel 2 exposes
  its gate, raw output, speaker enable, and combined speaker output through
  immutable snapshots. Tests cover terminal count, rate and square-wave
  cadence, latching, zero divisors, PIC interaction, port 61h, reset, and
  fragmented-versus-batched long runs. BCD counting and modes 1/4/5 remain
  outside the firmware/DOS subset until software requires them.

### M44 — CGA-compatible text-mode adapter ✅
- **Goal:** Make guest video memory, not a scripted boot scene, drive the CRT.
- **Build:** Map CGA text memory, implement the minimal CRTC/status/adapter ports
  needed for 80×25 text, and translate character/attribute cells into the
  existing `TextConsole`/Metal renderer. Snapshot video state across the
  core→UI boundary.
- **Don't:** Add graphics modes, composite-artifact color, or let the renderer
  read live emulator memory.
- **Tests:** VRAM mapping, character/attribute decoding, cursor registers,
  scrolling memory layouts, unmapped modes, snapshot immutability, and a visual
  fixture for the 80×25 frame.
- **Completed:** The bus carves a device-backed 16 KiB CGA window at
  B8000h–BBFFFh out of adapter space and maps the color CRTC, mode, palette, and
  deterministic status ports at 3D4h–3DAh. The adapter decodes the visible page
  from CRTC start/cursor addresses into 2,000 immutable CP437 character cells,
  including the 16-color foreground palette, background intensity versus blink,
  and cursor scan-line shape. Disabled, 40-column, and graphics configurations
  preserve VRAM/registers but render a blank unsupported-mode frame. The Metal
  view now consumes only `MachineSnapshot.video` through a locked copy; it no
  longer reads a scripted boot scene or live emulator memory. `TextConsole`
  renders decoded cells, character blink, and the CRTC cursor into the existing
  640×400 framebuffer. Tests cover memory/port boundaries, attributes, scrolling,
  cursor and status registers, unsupported modes, immutable snapshots, VRAM
  preservation across mode changes, and a palette/glyph visual fixture.
  Graphics modes and composite artifact color remain deferred.

### M45 — Keyboard/PPI input path ✅
- **Goal:** Deliver host keystrokes through PC-compatible hardware rather than
  directly into a console model.
- **Build:** Add the minimal 8255/PPI-compatible ports and keyboard scan-code
  queue needed by the selected BIOS contract, including IRQ1 through the PIC.
  Translate macOS key events at the workspace boundary.
- **Don't:** Bake Unicode characters into the hardware layer or make key repeat
  nondeterministic in tests.
- **Tests:** Make/break scan codes, modifiers, queue ordering/overflow policy,
  IRQ1 masking and acknowledgement, deterministic repeat, reset, and focus loss.
- **Completed:** The bus installs an XT-configuration 8255 PPI at ports
  60h–63h: port A latches keyboard scan codes, port B carries the keyboard
  clear/clock and speaker bits (gate and speaker-enable delegate to the PIT,
  which no longer maps 61h itself), port C mirrors timer-2 output, and the
  control register stores the XT operating mode. Scan codes queue behind the
  latch (capacity 16; overflow drops the newest and counts an overrun, never
  reordering earlier keystrokes). Delivery raises IRQ1; the port B bit-7
  pulse acknowledges the latch and redelivers the next code with a fresh
  edge. The authentic XT deadlock — a code latched before PIC initialization
  loses its edge and blocks the queue until POST's keyboard-clear pulse — is
  reproduced and pinned by a test. `Machine.postScanCode` is a lock-protected
  host inbox drained at instruction boundaries, so keystrokes are thread-safe
  against the execution queue and can wake HLT inside a running slice; idle
  workspaces drain explicitly. The workspace translates macOS virtual key
  codes to scan-code set 1 (83-key XT layout: keypad arrows, no E0
  extensions), forwards typematic repeats as extra makes, suppresses break
  codes for filtered host chords (⌘R), and releases all held keys on focus
  loss. A key-capture NSView over the CRT delivers raw keyDown/keyUp/
  flagsChanged events and treats Caps Lock toggles as make/break pairs; the
  inspector gains a KBD row (latched code + queue depth). **Deviation:** port
  B resets to 40h (keyboard clock enabled) instead of the 8255's all-zero
  reset so firmware-less machines still receive keystrokes. Verified in-app
  with the checked-in demo firmware: it clears CGA text memory, prints a boot
  greeting, then translates unshifted scan-code set 1 input to ASCII while
  exercising a guest-programmed PIC, one IRQ1 per keystroke, the 60h/61h
  handshake, EOI, and live CGA output while running.

### M46 — 8237-compatible DMA subset ✅
- **Goal:** Establish the transfer mechanism required by a PC floppy controller.
- **Build:** Implement the channel/register subset used for floppy DMA, including
  address/count programming, page register, terminal count, direction, masking,
  and cycle accounting through the system bus.
- **Don't:** Implement unused channels/modes speculatively or bypass memory-map
  protections.
- **Tests:** Device↔memory transfers, terminal count, 64 KiB boundary behavior,
  mask/request state, reset defaults, and deterministic clock impact.
- **Completed:** The PC bus now maps an 8237A-compatible controller at ports
  00h–0Fh and the floppy channel-2 page latch at 81h. Guest low/high byte
  programming establishes channel 2's base/current address and count; the
  shared byte pointer, command/status, software request, single/all-channel
  masks, mode, master clear, and clear-mask registers follow the PC contract.
  The implemented transfer subset is deliberately limited to channel 2,
  incrementing single mode without auto-initialization: verify, device→memory,
  and memory→device each service at most one DREQ byte. Counts use the 8237's
  N−1 convention, latch terminal count until status is read, and wrap the
  16-bit address inside a fixed page at 64 KiB. Terminal count produces internal
  EOP and masks channel 2 when auto-initialize is disabled, preventing an asserted
  DREQ from overrunning the programmed buffer. Transfers use ordinary bus
  reads/writes, retaining reserved/ROM protection diagnostics, and charge four
  deterministic system clocks through the machine clock so PIT/CGA time advances
  with stolen DMA cycles. Immutable machine snapshots expose the complete
  channel-2 state. Tests cover port programming, both data directions, terminal
  count/status clearing, page-boundary wrap, hardware/software requests,
  masking/controller disable, unsupported modes, reset/master clear, memory-map
  protection, and exact clock impact. Channels 0/1/3 and demand/block/cascade,
  decrement, and auto-initialize modes remain deferred until hardware needs them.

### M47 — Floppy controller + project disk image ✅
- **Goal:** Expose the project's disk image as a bootable PC floppy.
- **Build:** Implement the minimal 765-compatible command/result phases needed
  for reset, seek/recalibrate, sense interrupt, and DMA-backed sector reads;
  raise IRQ6 through the PIC. Add safe mount/eject and deterministic geometry
  detection for supported image sizes.
- **Don't:** Start with writes, copy protection, or every controller command.
- **Tests:** Command state machine, CHS reads, DMA/IRQ ordering, missing/bad media,
  end-of-track and bounds errors, reset, and fixture-image integrity.
- **Completed:** The PC bus now maps a minimal 765-compatible controller across
  ports 3F2h–3F7h with DOR reset/enable behavior, MSR phase reporting, command
  and result framing, SPECIFY, SENSE DRIVE STATUS, SENSE INTERRUPT, SEEK,
  RECALIBRATE, and READ DATA. Drive 0 accepts deterministic raw geometries from
  160 KiB through 1.44 MiB; READ DATA validates CHS/size/EOT, walks sectors
  (including multi-track reads), asserts channel-2 DREQ, and returns normal or
  abnormal seven-byte results. Each byte crosses the ordinary protected bus in
  a four-clock DMA service before terminal count ends execution and raises IRQ6,
  preserving completion-before-interrupt ordering even while the CPU is halted.
  Controller reset clears electronics and head position while retaining mounted
  host media. Project packages validate and copy selected images, remount them
  on reopen, and eject without deleting the package copy; the browser provides
  Choose/Eject controls and snapshots expose controller/media state to the
  inspector. Tests cover supported sizes, port phases, reset sense statuses,
  seek, invalid commands, exact fixture-sector integrity, DMA terminal count and
  IRQ ordering, missing media, EOT/cylinder failures, reset/eject, project reopen,
  snapshot publication, and rejection without metadata mutation. Writes,
  formatting, deleted-data scans, copy protection, and additional drives remain
  deferred.

### M48 — Clean-room BIOS foundation and diagnostics
- **Goal:** Execute real firmware from the reset vector and prove the whole
  machine before attempting DOS.
- **Build:** Add a reproducible firmware build artifact that initializes the
  IVT/BDA, PIC, PIT, video, keyboard, and floppy path; provide the minimal INT
  10h/13h/16h/1Ah services required by the boot path. Add a diagnostic ROM that
  reports pass/fail codes over text video and a test-only debug port.
- **Don't:** Copy proprietary IBM BIOS code; hide host-side shortcuts behind BIOS
  interrupt handlers.
- **Tests:** Reproducible ROM build, POST state, service contracts, diagnostic
  pass under bounded cycles, and failures that identify the responsible device.

### M49 — Boot-sector execution gate
- **Goal:** Reach and execute sector 0 from an unmodified disk image.
- **Build:** BIOS bootstrap loads the boot sector at 0000:7C00, validates media
  errors, establishes the documented register contract, and transfers control.
  Add debugger affordances for breakpoints, bounded run, memory inspection, and
  an instruction trace export so boot failures are diagnosable.
- **Don't:** Patch the boot sector or special-case its instruction stream.
- **Tests:** Known diagnostic boot sectors, bad signature/read failure paths,
  register/stack contract at handoff, deterministic trace golden files, and
  successful text output through emulated video.

### M50 — MS-DOS 2.0 boot, then MS-DOS 4.0 qualification
- **Goal:** First reach a stable MS-DOS 2.0 command prompt; only then qualify the
  broader MS-DOS 4.0 target.
- **Build:** Create pinned, reproducible disk fixtures from the Microsoft source
  release; close compatibility gaps using traces and focused regression tests.
  Define success as booting, keyboard input, timer progress, file reads, and a
  small command/program smoke suite. Repeat the suite for 4.0 after 2.0 is green.
- **Don't:** Add opcode or device hacks keyed to DOS addresses; claim App Store
  distributability without a separate packaging, attribution, trademark, and
  legal review.
- **Tests:** Bounded-cycle boot to prompt, `VER`/`DIR`/file-read fixtures,
  keyboard editing, timer rollover sanity, warm/cold reboot, deterministic disk
  reads, and a saved failure trace on timeout.

The intended dependency chain is now explicit:

```
CPU completeness → scheduling/memory → interrupts/timer → video/keyboard
                 → DMA/floppy → BIOS diagnostics → boot sector → DOS 2 → DOS 4
```

The Microsoft MS-DOS 1.25/2.0/4.0 source repository is MIT-licensed, making it a
useful source-level diagnostic reference and fixture input. Distribution inside
the shipping app remains a separate release/legal decision. Do not attempt the
DOS milestones until the M39 CPU coverage gate and M48 diagnostic ROM both pass.
