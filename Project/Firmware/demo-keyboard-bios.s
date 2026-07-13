// Minimal 8086 firmware used to exercise CGA text and the XT keyboard path.
// Assemble as a 256-byte, top-aligned ROM at F000:FF00.

    .code16
    .section __TEXT,__text
    .globl _start
_start:
    cli

    // Initialize the 8259 PIC and unmask only IRQ1.
    movb $0x11, %al
    outb %al, $0x20
    movb $0x20, %al
    outb %al, $0x21
    movb $0x04, %al
    outb %al, $0x21
    movb $0x01, %al
    outb %al, $0x21
    movb $0x00, %al
    outb %al, $0x21

    // Clear any keyboard latch left from before PIC initialization.
    inb $0x61, %al
    orb $0x80, %al
    outb %al, $0x61
    andb $0x7f, %al
    outb %al, $0x61

    // Enable CGA 80x25 text with blink.
    movw $0x03d8, %dx
    movb $0x29, %al
    outb %al, %dx

    // Install IRQ1 at interrupt vector 9 (0000:0084).
    xorw %ax, %ax
    movw %ax, %ds
    movw $0xff80, 0x0084
    movw $0xf000, 0x0086

    movw $0xf000, %ax
    movw %ax, %ds
    movw $0xb800, %ax
    movw %ax, %es
    xorw %di, %di

    // Clear all 2,000 visible cells to light-gray spaces.
    movw $0x0720, %ax
    movw $2000, %cx
    rep stosw

    // Prove the ROM/display path before waiting for keyboard input.
    xorw %di, %di
    movw $0xff60, %si
1:  lodsb
    testb %al, %al
    jz 2f
    movb $0x0a, %ah
    stosw
    jmp 1b
2:  sti
3:  hlt
    jmp 3b

    .org 0x60
message:
    .asciz "Hello World"

    .org 0x80
keyboard_interrupt:
    pushw %ax
    pushw %bx
    inb $0x60, %al
    testb $0x80, %al
    jnz acknowledge
    cmpb $0x39, %al
    ja acknowledge
    movw $0xffb0, %bx
    xlatb
    testb %al, %al
    jz acknowledge
    movb $0x0a, %ah
    stosw

acknowledge:
    inb $0x61, %al
    orb $0x80, %al
    outb %al, $0x61
    andb $0x7f, %al
    outb %al, $0x61
    movb $0x20, %al
    outb %al, $0x20
    popw %bx
    popw %ax
    iretw

    .org 0xb0
// Unshifted scan-code set 1. Zero entries are non-printing keys.
scan_code_ascii:
    .byte 0, 0, '1', '2', '3', '4', '5', '6'
    .byte '7', '8', '9', '0', '-', '=', 0, 0
    .byte 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i'
    .byte 'o', 'p', '[', ']', 0, 0, 'a', 's'
    .byte 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';'
    .byte '\'', '`', 0, '\\', 'z', 'x', 'c', 'v'
    .byte 'b', 'n', 'm', ',', '.', '/', 0, '*'
    .byte 0, ' '

    .org 0xf0
reset_vector:
    ljmp $0xf000, $0xff00
    .fill 11, 1, 0xf4
