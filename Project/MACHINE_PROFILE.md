# Sector Zero IBM PC Machine Profile

This document records Sector Zero's intentional compatibility choices and
known omissions. The target is an IBM-PC-compatible real-mode computer built
around an Intel 8086 core. It is not a cycle-exact IBM 5150 replica.

## CPU and timing

- The processor implements the documented original 8086 integer instruction
  set. It does not implement later x86 opcodes or operand/address-size modes.
- Instruction clocks follow 8086 timing. The machine does not reproduce the
  8088's narrower external bus, prefetch queue stalls, or exact bus waveform.
- Architecturally undefined flags are generally preserved. Decimal/ASCII and
  shift/rotate edge behavior follows the original 8086 policies documented in
  `ROADMAP.md`.
- Unsupported implementation gaps stop execution with an emulator diagnostic;
  they do not invent an invalid-opcode CPU exception. Reserved and documented
  alias encodings retain the completion policy established by M39.
- No 8087 is installed. WAIT observes a deterministic ready stub and ESC
  instructions reach a no-coprocessor endpoint after consuming their operands.

## Memory and firmware

- Physical addresses wrap at 20 bits. Conventional RAM occupies 00000h–9FFFFh,
  adapter space A0000h–EFFFFh, and system ROM F0000h–FFFFFh.
- Guest ROM writes are currently rejected and surfaced as a run-stopping
  diagnostic. Original PC hardware normally ignored them; this diagnostic may
  be demoted if real firmware uses harmless ROM-write probes.
- Firmware images are host-loaded, top-aligned in the 64 KiB system-ROM window,
  and must contain between 1 byte and 64 KiB.
- The clean-room BIOS is a 64 KiB image at F000:0000 with the architectural
  reset vector and conventional date/model identity at the top of ROM. All IVT
  entries point into firmware, with a state-preserving default for unimplemented
  vectors. It owns IRQ0/1/6 and implements INT 10h/AH=0Eh, INT 11h, INT 12h,
  INT 13h/AH=00h/02h, INT 14h, INT 16h/AH=00h/01h, INT 17h, and INT 1Ah/AH=00h.
  Other functions return unsupported status or remain outside the current BIOS
  contract.
- BIOS INT 13h reads currently support drive 0 and CHS values whose cylinder
  fits in CH. Callers must not cross a track or a 64 KiB DMA boundary in one
  request. INT 10h does not scroll, INT 16h uses a single-key latch rather than
  the IBM ring buffer, and INT 1Ah does not implement midnight rollover.
- Port E9h is a passive, test-only diagnostic recorder. It does not alter guest
  execution; snapshots retain a bounded sequence of POST progress/failure codes.
- The BIOS boot path reads drive 0 CHS 0/0/1 to 0000:7C00, requires a 55AAh
  signature, and transfers to 0000:7C00 with AX/BX/CX/DX/SI/DI/BP and
  DS/ES/SS zero, SP=7C00h, DL=00h, and IF clear. There is currently no boot-order
  scan, fixed-disk fallback, ROM BASIC, or configurable boot drive.

## Debugger

- Breakpoints are pre-execution physical-address stops, so segment aliases of
  the same 20-bit location share a breakpoint. Bounded runs count instruction,
  interrupt, DMA, and suspended-REP boundaries using the machine scheduler.
- Trace records contain the pre-boundary cycle, CS:IP, physical address, and
  first opcode byte. Workspace runs retain the newest 4,096 records and export
  a stable plain-text form. Physical-memory inspection is non-wrapping and uses
  the ordinary mapped bus view.

## Interrupts and timer

- One master 8259A is present. IRQ8–IRQ15, a slave PIC, and priority rotation
  are deferred. Fixed IRQ0-first priority is implemented.
- The 8253 subset implements binary modes 0, 2, and 3. BCD counting and modes
  1, 4, and 5 are deferred.
- One PIT input tick is generated per four emulated CPU clocks. Host wall-clock
  pacing never drives device state.
- Speaker channel-2 state is exposed, but no host audio is generated.

## Video and keyboard

- CGA support is limited to color 80×25 text mode and its 16 KiB B8000h window.
  Unsupported 40-column and graphics configurations preserve adapter state but
  render a blank frame. Composite artifact color is not modeled.
- Keyboard input uses scan-code set 1 for an 83-key XT layout. E0-extended keys
  are not modeled. The deterministic host queue holds 16 bytes and drops the
  newest byte on overflow.
- PPI port B resets to 40h so firmware-less machines can receive keyboard input;
  this intentionally differs from the 8255's all-zero reset state.

## DMA and storage

- The 8237A implementation is limited to channel 2, incrementing single mode,
  without auto-initialization. Verify, device-to-memory, and memory-to-device
  transfers are supported; each transferred byte costs four system clocks.
- Terminal count produces EOP, latches channel-2 TC status, clears a software
  request, and masks the non-auto-initializing channel. Address rollover stays
  inside the programmed 64 KiB page.
- Channels 0, 1, and 3 plus demand, block, cascade, decrement, and auto-initialize
  modes are deferred until required by hardware.
- A minimal 765-compatible controller is mapped at 3F2h–3F7h and connects drive
  0 to DMA channel 2 and PIC IRQ6. It implements reset, seek/recalibrate, sense
  commands, and read-only READ DATA command/result phases.
- Motor spin-up, rotational/index timing, seek delay, and a latched disk-change
  signal are not modeled; mounted drive 0 is immediately ready and port 3F7h
  reports only whether media is absent.
- Raw 160/180/320/360/720 KiB, 1.2 MiB, and 1.44 MiB images are detected by
  exact byte size. Project packages copy, persist, remount, and safely eject the
  selected image. Disk writes, formatting, copy protection, and additional
  drives are deferred.

## Determinism and UI boundary

- Devices advance from emulated CPU/DMA clocks on the machine execution context.
  They do not own threads and do not derive behavior from display refresh.
- Run-speed caps affect host pacing only. Throttle waits are interruptible for
  prompt pause; changing host speed cannot change emulated device results.
- Views consume immutable `MachineSnapshot` values. They do not read or mutate
  live CPU, memory, or device state.
