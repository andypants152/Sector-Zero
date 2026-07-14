# Demo keyboard BIOS

`demo-keyboard-bios.s` is the source for the small firmware used to verify the
M44 CGA and M45 keyboard paths. It boots at `F000:FF00`, clears the text screen,
prints `Hello World`, initializes IRQ1, and translates unshifted scan-code set 1
keys to ASCII before writing them to CGA memory.

The generated ROM must be exactly 256 bytes. Sector Zero top-aligns it in the
64 KiB system ROM window, placing the reset vector at `F000:FFF0`.

## M48 clean-room BIOS

`m48-bios.s` is the clean-room source for the 64 KiB `m48-bios.bin` system ROM.
Rebuild it with:

```sh
Project/Firmware/build-m48-bios.sh
```

The build uses Xcode's native assembler and a checked-in Swift Mach-O text
section extractor, so it requires no third-party assembler. Tests rebuild the
ROM and require byte-for-byte equality with the checked-in artifact. An optional
second build argument (`1`, `2`, `3`, or `6`) injects the corresponding POST
failure into a test-only ROM variant; `all` batches all four test variants into
the output directory.

From the architectural reset vector, the ROM initializes the IVT/BDA, CGA text
mode, master PIC, PIT channel 0, XT keyboard path, and floppy controller. POST
reports progress and device-specific failure codes to passive test port E9h and
prints its result through guest video. Its deliberately small boot-time service
surface is INT 10h/AH=0Eh, INT 11h, INT 12h, INT 13h/AH=00h/02h, INT 14h,
INT 16h/AH=00h/01h, INT 17h, and INT 1Ah/AH=00h. The absent serial and
printer services return deterministic timeout status. The keyboard table
includes the unshifted editing controls needed by DOS (Escape, Backspace, Tab,
and Enter).

M49 extends the same reproducible ROM with its bootstrap path. After POST it
reads drive 0 CHS 0/0/1 to physical 07C00h through INT 13h, requires the 55AAh
signature, and reports read/signature failures as E1h/E2h on port E9h and guest
text video. A successful handoff uses `CS:IP = 0000:7C00`, zeroes AX/BX/CX/DX,
SI/DI/BP and DS/ES/SS, sets SP to 7C00h, leaves interrupts disabled, and identifies
the only supported boot drive with DL=00h.

M50 retains the same standard INT 13h path for DOS file reads. Its ES:BX DMA
setup preserves all four page bits, including destinations in high conventional
RAM; focused tests cover a transfer into page 09h. The emulator also retains a
bounded controller-level history of validated CHS reads and DMA destinations for
boot-time failure reports.

M52 begins the full Sector Zero System BIOS arc. POST now gives all 256 IVT
vectors a safe ROM-resident endpoint before installing supported services and
IRQs. It publishes conventional equipment, memory-size, disk-status, mode-3
video, timer-rollover, and warm-boot fields in the BIOS data area. The standard
top-of-ROM identity locations contain the stable build date `07/13/26` and the
PC-compatible model byte `FFh`.

M53 completes the BIOS interface for the installed 80x25 CGA text mode. INT 10h
now supports mode set/query, cursor shape and per-page positions, four active
pages, rectangular scrolling and clearing, character/attribute reads and writes,
and teletype control characters with wrapping and scrolling. BDA, CRTC, and VRAM
state remain synchronized. Long dispatch branches use explicit 8086-safe short
conditions plus near jumps; the ROM never relies on the later `0F 8x` encoding.
