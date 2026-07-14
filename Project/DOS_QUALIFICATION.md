# External DOS qualification gate

Sector Zero does not bundle third-party operating-system images. M60 becomes a
completed compatibility qualification only after separately supplied DOS 2.0
and DOS 4.0 boot images pass the same bounded checklist.

For each image, configure `sector-zero-bios-1.0.bin`, mount a disposable copy of
the disk, and record the ROM checksum plus media SHA-256. Bound each run to two
million machine boundaries and require no CPU or memory-map fault.

1. Reach the command interpreter and run `VER` and `DIR`.
2. Read a known file from the mounted image and compare its displayed bytes or
   checksum with the host copy.
3. Type and edit a command using Backspace, Shift, Caps Lock, and Ctrl.
4. Confirm BIOS ticks advance while the prompt is idle.
5. Run a warm Ctrl-Alt-Del reboot and then a cold machine reset.
6. Repeat once after an intentional no-media boot failure and remount.

Record failures as compatibility gaps; do not change the documented BIOS
contract merely to match an undocumented behavior from one DOS release.
