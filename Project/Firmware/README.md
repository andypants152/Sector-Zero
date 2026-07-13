# Demo keyboard BIOS

`demo-keyboard-bios.s` is the source for the small firmware used to verify the
M44 CGA and M45 keyboard paths. It boots at `F000:FF00`, clears the text screen,
prints `Hello World`, initializes IRQ1, and translates unshifted scan-code set 1
keys to ASCII before writing them to CGA memory.

The generated ROM must be exactly 256 bytes. Sector Zero top-aligns it in the
64 KiB system ROM window, placing the reset vector at `F000:FFF0`.
