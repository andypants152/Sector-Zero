// Sector Zero M48 clean-room BIOS and diagnostic ROM.
// This source uses only documented 8086 instructions and PC-compatible ports.

    .code16
    .section __TEXT,__text
    .org 0xf000

// Tests may assemble a non-shipping variant that takes one POST failure path.
// The checked-in artifact and ordinary build always use zero (no injection).
    .ifndef FORCE_POST_FAILURE
    .set FORCE_POST_FAILURE, 0
    .endif

// BDA locations used by this minimal firmware (DS = 0000h).
    .set BDA_CURSOR,       0x0450
    .set BDA_TICKS_LOW,    0x046c
    .set BDA_TICKS_HIGH,   0x046e
    .set BDA_KEY_WORD,     0x0490
    .set BDA_KEY_READY,    0x0492
    .set FDC_DONE,         0x0493
    .set REQ_COUNT,        0x0494
    .set REQ_CYLINDER,     0x0495
    .set REQ_SECTOR,       0x0496
    .set REQ_HEAD,         0x0497
    .set REQ_DRIVE,        0x0498
    .set REQ_EOT,          0x0499

bios_entry:
    cli
    xorw %ax, %ax
    movw %ax, %ss
    movw $0x7000, %sp
    movw %ax, %ds
    movw %ax, %es

    movb $0x10, %al
    outb %al, $0xe9

    // Clear the IVT and the first 256 bytes of the BIOS data area.
    xorw %di, %di
    movw $640, %cx
    rep stosw

    // Install the firmware-owned software and hardware interrupt vectors.
    movw $irq0_handler, 0x0020
    movw $0xf000, 0x0022
    movw $irq1_handler, 0x0024
    movw $0xf000, 0x0026
    movw $irq6_handler, 0x0038
    movw $0xf000, 0x003a
    movw $int10_handler, 0x0040
    movw $0xf000, 0x0042
    movw $int13_handler, 0x004c
    movw $0xf000, 0x004e
    movw $int16_handler, 0x0058
    movw $0xf000, 0x005a
    movw $int1a_handler, 0x0068
    movw $0xf000, 0x006a

    movb $0x20, %al
    outb %al, $0xe9

    // Enable CGA 80x25 text, clear the visible page, and verify VRAM.
    movw $0x03d8, %dx
    movb $0x29, %al
    outb %al, %dx
    movw $0xb800, %ax
    movw %ax, %es
    xorw %di, %di
    movw $0x0720, %ax
    movw $2000, %cx
    rep stosw
    .if FORCE_POST_FAILURE == 2
    jmp fail_video
    .endif
    movw $0x1f5a, %es:0
    cmpw $0x1f5a, %es:0
    je video_test_passed
    jmp fail_video
video_test_passed:
    movw $0x0720, %es:0
    xorw %ax, %ax
    movw %ax, %es

    movb $0x30, %al
    outb %al, $0xe9

    // RAM diagnostic outside the IVT/BDA clear range.
    .if FORCE_POST_FAILURE == 1
    jmp fail_memory
    .endif
    movw $0xa55a, 0x0500
    cmpw $0xa55a, 0x0500
    je memory_test_passed
    jmp fail_memory
memory_test_passed:
    movw $0, 0x0500

    // Reset and sense the floppy controller before PIC initialization clears
    // its reset interrupt edge.
    call fdc_reset_and_sense
    movw $0x03f4, %dx
    inb %dx, %al
    .if FORCE_POST_FAILURE == 6
    jmp fail_floppy
    .endif
    cmpb $0x80, %al
    je floppy_test_passed
    jmp fail_floppy
floppy_test_passed:

    movb $0x40, %al
    outb %al, $0xe9

    // Master 8259A: vectors 08h-0Fh, edge-triggered, unmask IRQ0/1/6.
    movb $0x11, %al
    outb %al, $0x20
    movb $0x08, %al
    outb %al, $0x21
    movb $0x04, %al
    outb %al, $0x21
    movb $0x01, %al
    outb %al, $0x21
    movb $0xbc, %al
    outb %al, $0x21
    inb $0x21, %al
    .if FORCE_POST_FAILURE == 3
    jmp fail_pic
    .endif
    cmpb $0xbc, %al
    je pic_test_passed
    jmp fail_pic
pic_test_passed:

    // PIT channel 0, mode 3, divisor 65536 (18.2 Hz PC timebase).
    movb $0x36, %al
    outb %al, $0x43
    xorb %al, %al
    outb %al, $0x40
    outb %al, $0x40

    // Clear any stale XT keyboard latch through the PPI handshake.
    inb $0x61, %al
    orb $0x80, %al
    outb %al, $0x61
    andb $0x7f, %al
    outb %al, $0x61

    // Publish a clean BIOS-visible input/cursor state after device probing.
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, BDA_CURSOR
    movw %ax, BDA_KEY_WORD
    movb %al, BDA_KEY_READY
    movb %al, FDC_DONE

    movb $0x50, %al
    outb %al, $0xe9

    // Exercise the installed INT 10h contract to report POST state.
    movw $post_message, %si
    call print_string
    movb $0xaa, %al
    outb %al, $0xe9
    sti

bios_idle:
    hlt
    jmp bios_idle

fail_memory:
    movb $0xf1, %al
    jmp post_failure
fail_video:
    movb $0xf2, %al
    jmp post_failure
fail_pic:
    movb $0xf3, %al
    jmp post_failure
fail_floppy:
    movb $0xf6, %al
post_failure:
    outb %al, $0xe9
    movw $failure_message, %si
    call print_string
failure_halt:
    cli
    hlt
    jmp failure_halt

print_string:
    pushw %ax
print_string_next:
    movb %cs:(%si), %al
    incw %si
    testb %al, %al
    jz print_string_done
    movb $0x0e, %ah
    int $0x10
    jmp print_string_next
print_string_done:
    popw %ax
    ret

// Reset drive 0 and consume the four reset-status responses.
fdc_reset_and_sense:
    pushw %ax
    pushw %cx
    pushw %dx
    movw $0x03f2, %dx
    xorb %al, %al
    outb %al, %dx
    movb $0x0c, %al
    outb %al, %dx
    movw $0x03f5, %dx
    movw $4, %cx
fdc_sense_loop:
    movb $0x08, %al
    outb %al, %dx
    inb %dx, %al
    inb %dx, %al
    loop fdc_sense_loop
    popw %dx
    popw %cx
    popw %ax
    ret

irq0_handler:
    pushw %ax
    pushw %ds
    xorw %ax, %ax
    movw %ax, %ds
    incw BDA_TICKS_LOW
    jnz irq0_eoi
    incw BDA_TICKS_HIGH
irq0_eoi:
    movb $0x20, %al
    outb %al, $0x20
    popw %ds
    popw %ax
    iretw

irq1_handler:
    pushw %ax
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %ds
    inb $0x60, %al
    movb %al, %dl
    testb $0x80, %al
    jnz irq1_acknowledge
    cmpb $0x39, %al
    ja irq1_acknowledge
    movw $0xf000, %ax
    movw %ax, %ds
    movw $scan_code_ascii, %bx
    movb %dl, %al
    xlatb
    testb %al, %al
    jz irq1_acknowledge
    movb %al, %cl
    movb %dl, %ch
    xorw %ax, %ax
    movw %ax, %ds
    movw %cx, BDA_KEY_WORD
    movb $1, BDA_KEY_READY
irq1_acknowledge:
    inb $0x61, %al
    orb $0x80, %al
    outb %al, $0x61
    andb $0x7f, %al
    outb %al, $0x61
    movb $0x20, %al
    outb %al, $0x20
    popw %ds
    popw %dx
    popw %cx
    popw %bx
    popw %ax
    iretw

irq6_handler:
    pushw %ax
    pushw %ds
    xorw %ax, %ax
    movw %ax, %ds
    movb $1, FDC_DONE
    movb $0x20, %al
    outb %al, $0x20
    popw %ds
    popw %ax
    iretw

// INT 10h: AH=0Eh teletype output. Other functions return unchanged.
int10_handler:
    cmpb $0x0e, %ah
    jne int10_return
    pushw %ax
    pushw %bx
    pushw %di
    pushw %ds
    pushw %es
    xorw %bx, %bx
    movw %bx, %ds
    cmpb $0x0d, %al
    je int10_return_saved
    cmpb $0x0a, %al
    je int10_line_feed
    movw BDA_CURSOR, %di
    shlw $1, %di
    movw $0xb800, %bx
    movw %bx, %es
    movb $0x07, %ah
    stosw
    shrw $1, %di
    movw %di, BDA_CURSOR
    jmp int10_return_saved
int10_line_feed:
    addw $80, BDA_CURSOR
int10_return_saved:
    popw %es
    popw %ds
    popw %di
    popw %bx
    popw %ax
int10_return:
    iretw

// INT 16h: AH=00h waits and consumes a key; AH=01h peeks and returns ZF.
int16_handler:
    pushw %bp
    movw %sp, %bp
    pushw %ds
    pushw %bx
    xorw %bx, %bx
    movw %bx, %ds
    cmpb $0x00, %ah
    je int16_wait
    cmpb $0x01, %ah
    je int16_check
    movb $0x86, %ah
    orb $0x01, 6(%bp)
    jmp int16_done
int16_wait:
    sti
int16_wait_loop:
    cmpb $0, BDA_KEY_READY
    jne int16_take
    hlt
    jmp int16_wait_loop
int16_take:
    movw BDA_KEY_WORD, %ax
    movb $0, BDA_KEY_READY
    andb $0xbe, 6(%bp)
    jmp int16_done
int16_check:
    cmpb $0, BDA_KEY_READY
    je int16_empty
    movw BDA_KEY_WORD, %ax
    andb $0xbe, 6(%bp)
    jmp int16_done
int16_empty:
    orb $0x40, 6(%bp)
int16_done:
    popw %bx
    popw %ds
    popw %bp
    iretw

// INT 1Ah: AH=00h returns the 32-bit BIOS tick count in CX:DX.
int1a_handler:
    pushw %bp
    movw %sp, %bp
    pushw %ds
    xorw %dx, %dx
    movw %dx, %ds
    cmpb $0, %ah
    jne int1a_unsupported
    movw BDA_TICKS_LOW, %dx
    movw BDA_TICKS_HIGH, %cx
    xorw %ax, %ax
    andb $0xfe, 6(%bp)
    jmp int1a_done
int1a_unsupported:
    movb $0x86, %ah
    orb $1, 6(%bp)
int1a_done:
    popw %ds
    popw %bp
    iretw

// INT 13h: AH=00h controller reset; AH=02h read CHS sectors to ES:BX.
int13_handler:
    pushw %bp
    movw %sp, %bp
    cmpb $0, %ah
    je int13_reset
    cmpb $2, %ah
    je int13_read
    movb $1, %ah
    xorb %al, %al
    orb $1, 6(%bp)
    popw %bp
    iretw

int13_reset:
    call fdc_reset_and_sense
    xorw %ax, %ax
    andb $0xfe, 6(%bp)
    popw %bp
    iretw

int13_read:
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %si
    pushw %di
    pushw %ds
    xorw %si, %si
    movw %si, %ds
    cmpb $0, %dl
    je int13_drive_valid
    jmp int13_bad_request
int13_drive_valid:
    testb %al, %al
    jnz int13_request_valid
    jmp int13_bad_request
int13_request_valid:
    movb %al, REQ_COUNT
    movb %ch, REQ_CYLINDER
    movb %cl, REQ_SECTOR
    movb %dh, REQ_HEAD
    movb %dl, REQ_DRIVE
    movb %cl, %ah
    addb REQ_COUNT, %ah
    decb %ah
    movb %ah, REQ_EOT

    // Compute the 20-bit ES:BX destination as DMA page DL + address SI.
    movw %es, %dx
    movb $12, %cl
    shrw %cl, %dx
    movw %es, %ax
    movb $4, %cl
    shlw %cl, %ax
    addw %bx, %ax
    adcb $0, %dl
    movw %ax, %si

    xorw %ax, %ax
    movb REQ_COUNT, %al
    movw $512, %cx
    mulw %cx
    decw %ax
    movw %ax, %di

    movb $0x06, %al
    outb %al, $0x0a
    xorb %al, %al
    outb %al, $0x0c
    movw %si, %ax
    outb %al, $0x04
    movb %ah, %al
    outb %al, $0x04
    movw %di, %ax
    outb %al, $0x05
    movb %ah, %al
    outb %al, $0x05
    movb %dl, %al
    outb %al, $0x81
    movb $0x46, %al
    outb %al, $0x0b
    movb $0x02, %al
    outb %al, $0x0a

    movb $0, FDC_DONE
    movw $0x03f2, %dx
    movb $0x0c, %al
    outb %al, %dx
    movw $0x03f5, %dx
    movb $0xe6, %al
    outb %al, %dx
    movb REQ_HEAD, %al
    shlb $1, %al
    shlb $1, %al
    orb REQ_DRIVE, %al
    outb %al, %dx
    movb REQ_CYLINDER, %al
    outb %al, %dx
    movb REQ_HEAD, %al
    outb %al, %dx
    movb REQ_SECTOR, %al
    outb %al, %dx
    movb $2, %al
    outb %al, %dx
    movb REQ_EOT, %al
    outb %al, %dx
    movb $0x1b, %al
    outb %al, %dx
    movb $0xff, %al
    outb %al, %dx

    sti
int13_wait_irq:
    cmpb $0, FDC_DONE
    jne int13_results
    hlt
    jmp int13_wait_irq

int13_results:
    inb %dx, %al
    movb %al, %bl
    inb %dx, %al
    movb %al, %bh
    inb %dx, %al
    movb %al, %cl
    inb %dx, %al
    inb %dx, %al
    inb %dx, %al
    inb %dx, %al
    testb $0xc0, %bl
    jnz int13_read_error
    testb %bh, %bh
    jnz int13_read_error
    testb %cl, %cl
    jnz int13_read_error
    xorw %ax, %ax
    movb REQ_COUNT, %al
    andb $0xfe, 6(%bp)
    jmp int13_read_done

int13_bad_request:
    movb $1, %ah
    xorb %al, %al
    orb $1, 6(%bp)
    jmp int13_read_done
int13_read_error:
    movb $0x20, %ah
    xorb %al, %al
    orb $1, 6(%bp)
int13_read_done:
    popw %ds
    popw %di
    popw %si
    popw %dx
    popw %cx
    popw %bx
    popw %bp
    iretw

post_message:
    .asciz "Sector Zero BIOS M48 - POST PASS"
failure_message:
    .asciz "Sector Zero BIOS M48 - POST FAIL"

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

    .org 0xfff0
reset_vector:
    ljmp $0xf000, $bios_entry
    .fill 11, 1, 0xf4
