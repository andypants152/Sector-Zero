// Sector Zero clean-room System BIOS 1.0 (originating at milestone M48).
// This source uses only documented 8086 instructions and PC-compatible ports.

    .code16
    .section __TEXT,__text
    // Reserve the upper 16 KiB of the 64 KiB system ROM for executable BIOS
    // code and tables while keeping the architectural reset vector at FFF0h.
    .org 0xc000

// Tests may assemble a non-shipping variant that takes one POST failure path.
// The checked-in artifact and ordinary build always use zero (no injection).
    .ifndef FORCE_POST_FAILURE
    .set FORCE_POST_FAILURE, 0
    .endif

// Canonical PC BIOS data-area locations (DS = 0000h).
    .set BDA_EQUIPMENT,    0x0410
    .set BDA_MEMORY_KB,    0x0413
    .set BDA_KB_FLAGS1,    0x0417
    .set BDA_KB_FLAGS2,    0x0418
    .set BDA_KB_HEAD,      0x041a
    .set BDA_KB_TAIL,      0x041c
    .set BDA_KB_BUFFER,    0x041e
    .set BDA_KB_BUFFER_END,0x043e
    .set BDA_DISK_STATUS,  0x0441
    .set BDA_VIDEO_MODE,   0x0449
    .set BDA_COLUMNS,      0x044a
    .set BDA_PAGE_SIZE,    0x044c
    .set BDA_PAGE_OFFSET,  0x044e
    .set BDA_CURSOR,       0x0450
    .set BDA_CURSOR_SHAPE, 0x0460
    .set BDA_ACTIVE_PAGE,  0x0462
    .set BDA_CRTC_BASE,    0x0463
    .set BDA_MODE_CONTROL, 0x0465
    .set BDA_COLOR_SELECT, 0x0466
    .set BDA_TICKS_LOW,    0x046c
    .set BDA_TICKS_HIGH,   0x046e
    .set BDA_MIDNIGHT,     0x0470
    .set BDA_WARM_BOOT,    0x0472
    .set BDA_FIXED_STATUS, 0x0474
    .set BDA_FIXED_COUNT,  0x0475
    .set BDA_KB_START,     0x0480
    .set BDA_KB_END,       0x0482
    .set BDA_KEY_WORD,     0x0490
    .set BDA_KEY_READY,    0x0492
    .set FDC_DONE,         0x0493
    .set REQ_COUNT,        0x0494
    .set REQ_CYLINDER,     0x0495
    .set REQ_SECTOR,       0x0496
    .set REQ_HEAD,         0x0497
    .set REQ_DRIVE,        0x0498
    .set REQ_EOT,          0x0499
    .set VIDEO_TOP,        0x049a
    .set VIDEO_LEFT,       0x049b
    .set VIDEO_BOTTOM,     0x049c
    .set VIDEO_RIGHT,      0x049d
    .set VIDEO_LINES,      0x049e
    .set VIDEO_ATTRIBUTE,  0x049f
    .set VIDEO_PAGE,       0x04a0
    .set VIDEO_CHARACTER,  0x04a1
    .set VIDEO_DIRECTION,  0x04a2
    .set DISK_GEOM_SPT,    0x04a3
    .set DISK_GEOM_HEADS,  0x04a4
    .set DISK_GEOM_TRACKS, 0x04a5
    .set REQ_DMA_OFFSET,   0x04a6
    .set REQ_DMA_PAGE,     0x04a8
    .set REQ_REMAINING,    0x04a9
    .set REQ_ORIGINAL,     0x04aa
    .set REQ_COMMAND,      0x04ab
    .set REQ_DMA_MODE,     0x04ac
    .set FIXED_CYLINDER,   0x04ad
    .set BOOT_FAILURE_KIND,0x04af
    .set POST_WARM_FLAG,   0x0504

bios_entry:
    cli
    xorw %ax, %ax
    movw %ax, %ss
    movw $0x7000, %sp
    movw %ax, %ds
    movw %ax, %es
    cmpw $0x1234, BDA_WARM_BOOT
    jne bios_cold_entry
    movb $1, POST_WARM_FLAG
    movb $0x11, %al
    jmp bios_entry_report
bios_cold_entry:
    movb $0, POST_WARM_FLAG
    movb $0x10, %al
bios_entry_report:
    outb %al, $0xe9

    // Give every interrupt a safe firmware-owned endpoint before installing
    // the services and IRQs implemented by this machine.
    xorw %di, %di
    movw $default_interrupt_handler, %ax
    movw $0xf000, %dx
    movw $256, %cx
initialize_ivt:
    stosw
    xchgw %ax, %dx
    stosw
    xchgw %ax, %dx
    loop initialize_ivt

    // Clear the 256-byte BIOS data area before publishing platform state.
    movw $0x0400, %di
    xorw %ax, %ax
    movw $128, %cx
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
    movw $int11_handler, 0x0044
    movw $0xf000, 0x0046
    movw $int12_handler, 0x0048
    movw $0xf000, 0x004a
    movw $int13_handler, 0x004c
    movw $0xf000, 0x004e
    movw $int14_handler, 0x0050
    movw $0xf000, 0x0052
    movw $int15_handler, 0x0054
    movw $0xf000, 0x0056
    movw $int16_handler, 0x0058
    movw $0xf000, 0x005a
    movw $int17_handler, 0x005c
    movw $0xf000, 0x005e
    movw $int18_handler, 0x0060
    movw $0xf000, 0x0062
    movw $int19_handler, 0x0064
    movw $0xf000, 0x0066
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
    cmpb $0, POST_WARM_FLAG
    jne memory_test_passed
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

    // Publish the standard PC platform and mode-3 text fields. Later BIOS
    // services update these values instead of maintaining private shadows.
    movw $0x0061, BDA_EQUIPMENT
    movw $640, BDA_MEMORY_KB
    movb $0, BDA_DISK_STATUS
    movb $0, BDA_FIXED_STATUS
    movb $0, BDA_FIXED_COUNT
    movw $0x02a1, %dx
    xorb %al, %al
    outb %al, %dx
    decw %dx
    movb $0xec, %al
    outb %al, %dx
    inb %dx, %al
    cmpb $0x40, %al
    jne 1f
    movb $1, BDA_FIXED_COUNT
1:
    movb $0, BDA_KB_FLAGS1
    movb $0, BDA_KB_FLAGS2
    movw $0x001e, BDA_KB_HEAD
    movw $0x001e, BDA_KB_TAIL
    movw $0x001e, BDA_KB_START
    movw $0x003e, BDA_KB_END
    movb $3, BDA_VIDEO_MODE
    movw $80, BDA_COLUMNS
    movw $0x1000, BDA_PAGE_SIZE
    movw $0, BDA_PAGE_OFFSET
    movw $0x0607, BDA_CURSOR_SHAPE
    movb $0, BDA_ACTIVE_PAGE
    movw $0x03d4, BDA_CRTC_BASE
    movb $0x29, BDA_MODE_CONTROL
    movb $0, BDA_COLOR_SELECT
    movb $0, BDA_MIDNIGHT
    movw $0, BDA_WARM_BOOT

    // Keep the hardware cursor shape, start address, and position synchronized
    // with the mode-3 state just published in the BDA.
    movw $0x03d4, %dx
    movb $0x0a, %al
    outb %al, %dx
    incw %dx
    movb $6, %al
    outb %al, %dx
    decw %dx
    movb $0x0b, %al
    outb %al, %dx
    incw %dx
    movb $7, %al
    outb %al, %dx
    xorw %ax, %ax
    call video_program_start
    call video_program_cursor

    movb $0x50, %al
    outb %al, $0xe9

    // Exercise the installed INT 10h contract to report POST state.
    movw $post_message, %si
    call print_string
    movb $0xaa, %al
    outb %al, $0xe9

bootstrap:
    // Read drive 0, cylinder 0, head 0, sector 1 through the
    // ordinary INT 13h/FDC/DMA path, validate 55AAh, then establish the
    // documented Sector Zero boot contract before a far transfer.
    movb $0xb0, %al
    outb %al, $0xe9
    movb $0, BOOT_FAILURE_KIND
    sti
    xorw %ax, %ax
    movw %ax, %es
    movw $0x0201, %ax
    movw $0x7c00, %bx
    movw $0x0001, %cx
    xorw %dx, %dx
    int $0x13
    jc boot_try_fixed
    movb $0xb1, %al
    outb %al, $0xe9
    cmpw $0xaa55, 0x7dfe
    jne boot_floppy_bad_signature
    movb $0xb2, %al
    outb %al, $0xe9

    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7c00, %sp
    movw %ax, %bx
    movw %ax, %cx
    movw %ax, %dx
    movb REQ_DRIVE, %dl
    movw %ax, %si
    movw %ax, %di
    movw %ax, %bp
    ljmp $0x0000, $0x7c00

boot_floppy_bad_signature:
    movb $1, BOOT_FAILURE_KIND
boot_try_fixed:
    xorw %ax, %ax
    movw %ax, %es
    movw $0x0201, %ax
    movw $0x7c00, %bx
    movw $0x0001, %cx
    movw $0x0080, %dx
    int $0x13
    jc boot_fixed_read_failure
    cmpw $0xaa55, 0x7dfe
    jne boot_signature_failure
    movb $0xb2, %al
    outb %al, $0xe9
    jmp 1f
boot_fixed_read_failure:
    cmpb $0, BOOT_FAILURE_KIND
    jne boot_signature_failure
    jmp boot_read_failure
1:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7c00, %sp
    movw %ax, %bx
    movw %ax, %cx
    movw %ax, %dx
    movb $0x80, %dl
    movw %ax, %si
    movw %ax, %di
    movw %ax, %bp
    ljmp $0x0000, $0x7c00

bios_idle:
    hlt
    jmp bios_idle

boot_read_failure:
    movb $0xe1, %al
    movw $boot_read_failure_message, %si
    jmp boot_failure
boot_signature_failure:
    movb $0xe2, %al
    movw $boot_signature_failure_message, %si
boot_failure:
    outb %al, $0xe9
    call print_string
    int $0x18

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
    pushw %bx
    xorw %bx, %bx
print_string_next:
    movb %cs:(%si), %al
    incw %si
    testb %al, %al
    jz print_string_done
    movb $0x0e, %ah
    int $0x10
    jmp print_string_next
print_string_done:
    popw %bx
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

// Discover mounted-media geometry with SEEK plus READ ID. The controller's
// deterministic READ ID rotation returns the final sector number on a track.
fdc_detect_geometry:
    pushw %ax
    pushw %bx
    pushw %cx
    pushw %dx
    movw $0x03f2, %dx
    movb REQ_DRIVE, %al
    orb $0x0c, %al
    outb %al, %dx
    movw $0x03f7, %dx
    inb %dx, %al
    testb $0x80, %al
    jnz fdc_geometry_failed
    movb $79, %ch
    xorb %dh, %dh
    call fdc_probe_id
    jc fdc_geometry_40_track
    movb $80, DISK_GEOM_TRACKS
    jmp fdc_geometry_probe_heads
fdc_geometry_40_track:
    movb $39, %ch
    xorb %dh, %dh
    call fdc_probe_id
    jc fdc_geometry_failed
    movb $40, DISK_GEOM_TRACKS
fdc_geometry_probe_heads:
    movb DISK_GEOM_SPT, %al
    movb %al, REQ_EOT
    movb DISK_GEOM_TRACKS, %ch
    decb %ch
    movb $1, %dh
    call fdc_probe_id
    movb REQ_EOT, %al
    movb %al, DISK_GEOM_SPT
    jc fdc_geometry_one_head
    movb $2, DISK_GEOM_HEADS
    jmp fdc_geometry_done
fdc_geometry_one_head:
    movb $1, DISK_GEOM_HEADS
fdc_geometry_done:
    popw %dx
    popw %cx
    popw %bx
    popw %ax
    clc
    ret
fdc_geometry_failed:
    popw %dx
    popw %cx
    popw %bx
    popw %ax
    stc
    ret

// Probe CH cylinder and DH head. Return CF clear and cache sectors/track when
// the standard READ ID result is successful; consume every result byte.
fdc_probe_id:
    movb %ch, REQ_CYLINDER
    movb %dh, REQ_HEAD
    movb $0, FDC_DONE
    movw $0x03f5, %dx
    movb $0x0f, %al
    outb %al, %dx
    movb REQ_HEAD, %al
    shlb $1, %al
    shlb $1, %al
    orb REQ_DRIVE, %al
    outb %al, %dx
    movb REQ_CYLINDER, %al
    outb %al, %dx
    sti
1:
    cmpb $0, FDC_DONE
    jne 2f
    nop
    jmp 1b
2:
    cli
    movb $0x08, %al
    outb %al, %dx
    inb %dx, %al
    inb %dx, %al

    movb $0, FDC_DONE
    movb $0x0a, %al
    outb %al, %dx
    movb REQ_HEAD, %al
    shlb $1, %al
    shlb $1, %al
    orb REQ_DRIVE, %al
    outb %al, %dx
    sti
1:
    cmpb $0, FDC_DONE
    jne 2f
    nop
    jmp 1b
2:
    cli
    inb %dx, %al
    movb %al, %bl
    andb $0xc0, %bl
    inb %dx, %al
    orb %al, %bl
    inb %dx, %al
    orb %al, %bl
    inb %dx, %al
    inb %dx, %al
    inb %dx, %al
    movb %al, DISK_GEOM_SPT
    inb %dx, %al
    testb %bl, %bl
    jnz 1f
    clc
    ret
1:
    stc
    ret

irq0_handler:
    pushw %ax
    pushw %ds
    xorw %ax, %ax
    movw %ax, %ds
    incw BDA_TICKS_LOW
    jnz irq0_check_rollover
    incw BDA_TICKS_HIGH
irq0_check_rollover:
    cmpw $0x0018, BDA_TICKS_HIGH
    jb irq0_eoi
    cmpw $0x00b0, BDA_TICKS_LOW
    jb irq0_eoi
    movw $0, BDA_TICKS_LOW
    movw $0, BDA_TICKS_HIGH
    incb BDA_MIDNIGHT
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
    xorw %ax, %ax
    movw %ax, %ds
    testb $0x80, %dl
    jz irq1_make
    andb $0x7f, %dl
    cmpb $0x2a, %dl
    jne 1f
    andb $0xfd, BDA_KB_FLAGS1
    jmp irq1_acknowledge
1:
    cmpb $0x36, %dl
    jne 1f
    andb $0xfe, BDA_KB_FLAGS1
    jmp irq1_acknowledge
1:
    cmpb $0x1d, %dl
    jne 1f
    andb $0xfb, BDA_KB_FLAGS1
    andb $0xfe, BDA_KB_FLAGS2
    jmp irq1_acknowledge
1:
    cmpb $0x38, %dl
    jne 1f
    andb $0xf7, BDA_KB_FLAGS1
    andb $0xfd, BDA_KB_FLAGS2
    jmp irq1_acknowledge
1:
    cmpb $0x3a, %dl
    jne 1f
    andb $0xbf, BDA_KB_FLAGS2
    jmp irq1_acknowledge
1:
    cmpb $0x45, %dl
    jne 1f
    andb $0xdf, BDA_KB_FLAGS2
    jmp irq1_acknowledge
1:
    cmpb $0x46, %dl
    je 1f
    jmp irq1_acknowledge
1:
    andb $0xef, BDA_KB_FLAGS2
    jmp irq1_acknowledge

irq1_make:
    cmpb $0x2a, %dl
    jne 1f
    orb $0x02, BDA_KB_FLAGS1
    jmp irq1_acknowledge
1:
    cmpb $0x36, %dl
    jne 1f
    orb $0x01, BDA_KB_FLAGS1
    jmp irq1_acknowledge
1:
    cmpb $0x1d, %dl
    jne 1f
    orb $0x04, BDA_KB_FLAGS1
    orb $0x01, BDA_KB_FLAGS2
    jmp irq1_acknowledge
1:
    cmpb $0x38, %dl
    jne 1f
    orb $0x08, BDA_KB_FLAGS1
    orb $0x02, BDA_KB_FLAGS2
    jmp irq1_acknowledge
1:
    cmpb $0x3a, %dl
    jne 1f
    testb $0x40, BDA_KB_FLAGS2
    jz 2f
    jmp irq1_acknowledge
2:
    orb $0x40, BDA_KB_FLAGS2
    xorb $0x40, BDA_KB_FLAGS1
    jmp irq1_acknowledge
1:
    cmpb $0x45, %dl
    jne 1f
    testb $0x20, BDA_KB_FLAGS2
    jz 2f
    jmp irq1_acknowledge
2:
    orb $0x20, BDA_KB_FLAGS2
    xorb $0x20, BDA_KB_FLAGS1
    jmp irq1_acknowledge
1:
    cmpb $0x46, %dl
    jne irq1_regular_make
    testb $0x10, BDA_KB_FLAGS2
    jz 2f
    jmp irq1_acknowledge
2:
    orb $0x10, BDA_KB_FLAGS2
    xorb $0x10, BDA_KB_FLAGS1
    jmp irq1_acknowledge

irq1_regular_make:
    // Ctrl-Alt-Del requests a firmware warm restart through the canonical
    // BDA marker. The later lifecycle milestone distinguishes warm POST work.
    cmpb $0x53, %dl
    jne 1f
    movb BDA_KB_FLAGS1, %al
    andb $0x0c, %al
    cmpb $0x0c, %al
    jne 1f
    movw $0x1234, BDA_WARM_BOOT
    ljmp $0xf000, $bios_entry
1:
    cmpb $0x53, %dl
    jbe 1f
    jmp irq1_acknowledge
1:
    xorw %bx, %bx
    movb %dl, %bl
    movb %cs:scan_code_ascii(%bx), %al
    movb BDA_KB_FLAGS1, %ah
    testb $0x08, %ah
    jz irq1_not_alt
    xorb %al, %al
    jmp irq1_enqueue
irq1_not_alt:
    testb $0x04, %ah
    jz irq1_not_control
    cmpb $'a', %al
    jb irq1_enqueue
    cmpb $'z', %al
    ja irq1_enqueue
    andb $0x1f, %al
    jmp irq1_enqueue
irq1_not_control:
    // Caps Lock affects letters and composes with Shift as an XOR.
    cmpb $'a', %al
    jb irq1_nonletter
    cmpb $'z', %al
    ja irq1_nonletter
    movb %ah, %cl
    andb $0x03, %cl
    jz 1f
    movb $1, %cl
    jmp 2f
1:
    xorb %cl, %cl
2:
    testb $0x40, %ah
    jz 3f
    xorb $1, %cl
3:
    testb %cl, %cl
    jz irq1_enqueue
    subb $32, %al
    jmp irq1_enqueue
irq1_nonletter:
    testb $0x03, %ah
    jz irq1_keypad
    movb %cs:scan_code_shifted(%bx), %al
irq1_keypad:
    // The XT numeric keypad produces ASCII only while Num Lock is active;
    // navigation forms retain a zero ASCII byte and their scan code.
    cmpb $0x47, %dl
    jb irq1_enqueue
    cmpb $0x53, %dl
    ja irq1_enqueue
    testb $0x20, %ah
    jz 1f
    movb %cs:scan_code_numeric(%bx), %al
    jmp irq1_enqueue
1:
    xorb %al, %al
irq1_enqueue:
    testb %al, %al
    jnz 1f
    testb $0x08, BDA_KB_FLAGS1
    jnz 1f
    cmpb $0x47, %dl
    jb irq1_acknowledge
1:
    movb %al, %cl
    movb %dl, %ch
    call keyboard_enqueue
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

// Enqueue CX as scan:ASCII in the canonical 16-word BDA circular buffer.
// Full buffers retain the oldest keys and drop the newest key deterministically.
keyboard_enqueue:
    pushw %ax
    pushw %bx
    pushw %dx
    movw BDA_KB_TAIL, %bx
    movw %bx, %dx
    addw $2, %dx
    cmpw BDA_KB_END, %dx
    jb 1f
    movw BDA_KB_START, %dx
1:
    cmpw BDA_KB_HEAD, %dx
    je 1f
    movw %cx, 0x0400(%bx)
    movw %dx, BDA_KB_TAIL
1:
    popw %dx
    popw %bx
    popw %ax
    ret

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

// Unimplemented and reserved vectors return without mutating caller state.
// Every exposed hardware IRQ and supported BIOS service is installed above.
default_interrupt_handler:
    iretw

// INT 11h/12h: PC-compatible equipment and conventional-memory reports.
// The equipment word advertises diskette hardware, one installed drive, and
// 80x25 color video. Conventional RAM occupies the complete 640 KiB PC range.
int11_handler:
    movw $0x0061, %ax
    iretw

int12_handler:
    movw $640, %ax
    iretw

// INT 14h/17h: deterministic absent serial and printer devices. Their status
// bits report timeout/not-ready, matching the zero port counts in INT 11h.
int14_handler:
    movw $0x8000, %ax
    iretw

int17_handler:
    movb $0x01, %ah
    iretw

// INT 15h/AH=88h truthfully reports no extended memory on this 640 KiB XT.
// AT-only waits, configuration tables, and protected-mode services are absent.
int15_handler:
    pushw %bp
    movw %sp, %bp
    cmpb $0x88, %ah
    jne int15_unsupported
    xorw %ax, %ax
    andb $0xfe, 6(%bp)
    popw %bp
    iretw
int15_unsupported:
    movb $0x86, %ah
    orb $0x01, 6(%bp)
    popw %bp
    iretw

// INT 18h is the ROM no-boot endpoint. It is deliberately terminal but keeps
// interrupts enabled so timer state remains a truthful running machine clock.
int18_handler:
    movb $0xe8, %al
    outb %al, $0xe9
int18_halt:
    sti
    hlt
    jmp int18_halt

// INT 19h discards the caller's stack context and restarts the ordinary BIOS
// bootstrap path. It never bypasses INT 13h or boot-signature validation.
int19_handler:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7000, %sp
    jmp bootstrap

// INT 10h: complete text-mode services for the installed 80x25 CGA adapter.
int10_handler:
    cmpb $0x00, %ah
    jne int10_dispatch_01
    jmp int10_set_mode
int10_dispatch_01:
    cmpb $0x01, %ah
    jne int10_dispatch_02
    jmp int10_set_cursor_shape
int10_dispatch_02:
    cmpb $0x02, %ah
    jne int10_dispatch_03
    jmp int10_set_cursor_position
int10_dispatch_03:
    cmpb $0x03, %ah
    jne int10_dispatch_05
    jmp int10_get_cursor_position
int10_dispatch_05:
    cmpb $0x05, %ah
    jne int10_dispatch_06
    jmp int10_select_page
int10_dispatch_06:
    cmpb $0x06, %ah
    jne int10_dispatch_07
    jmp int10_scroll_up
int10_dispatch_07:
    cmpb $0x07, %ah
    jne int10_dispatch_08
    jmp int10_scroll_down
int10_dispatch_08:
    cmpb $0x08, %ah
    jne int10_dispatch_09
    jmp int10_read_character
int10_dispatch_09:
    cmpb $0x09, %ah
    jne int10_dispatch_0a
    jmp int10_write_character_attribute
int10_dispatch_0a:
    cmpb $0x0a, %ah
    jne int10_dispatch_0e
    jmp int10_write_character
int10_dispatch_0e:
    cmpb $0x0e, %ah
    jne int10_dispatch_0f
    jmp int10_teletype
int10_dispatch_0f:
    cmpb $0x0f, %ah
    jne int10_return
    jmp int10_get_mode
int10_return:
    iretw

int10_set_mode:
    cmpb $3, %al
    jne int10_return
    pushw %ax
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %di
    pushw %ds
    pushw %es
    xorw %bx, %bx
    movw %bx, %ds
    movw $0xb800, %bx
    movw %bx, %es
    xorw %di, %di
    movw $0x0720, %ax
    movw $8192, %cx
    rep stosw
    xorw %ax, %ax
    movw %ax, BDA_PAGE_OFFSET
    movw %ax, BDA_CURSOR
    movw %ax, BDA_CURSOR+2
    movw %ax, BDA_CURSOR+4
    movw %ax, BDA_CURSOR+6
    movw %ax, BDA_CURSOR+8
    movw %ax, BDA_CURSOR+10
    movw %ax, BDA_CURSOR+12
    movw %ax, BDA_CURSOR+14
    movb $3, BDA_VIDEO_MODE
    movw $80, BDA_COLUMNS
    movw $0x1000, BDA_PAGE_SIZE
    movw $0x0607, BDA_CURSOR_SHAPE
    movb $0, BDA_ACTIVE_PAGE
    movb $0x29, BDA_MODE_CONTROL
    movb $0, BDA_COLOR_SELECT
    movw $0x03d8, %dx
    movb $0x29, %al
    outb %al, %dx
    incw %dx
    xorb %al, %al
    outb %al, %dx
    movw $0x03d4, %dx
    movb $0x0a, %al
    outb %al, %dx
    incw %dx
    movb $6, %al
    outb %al, %dx
    decw %dx
    movb $0x0b, %al
    outb %al, %dx
    incw %dx
    movb $7, %al
    outb %al, %dx
    xorw %ax, %ax
    call video_program_start
    call video_program_cursor
    popw %es
    popw %ds
    popw %di
    popw %dx
    popw %cx
    popw %bx
    popw %ax
    iretw

int10_set_cursor_shape:
    pushw %ax
    pushw %dx
    pushw %ds
    xorw %ax, %ax
    movw %ax, %ds
    movw %cx, BDA_CURSOR_SHAPE
    movw $0x03d4, %dx
    movb $0x0a, %al
    outb %al, %dx
    incw %dx
    movb %ch, %al
    outb %al, %dx
    decw %dx
    movb $0x0b, %al
    outb %al, %dx
    incw %dx
    movb %cl, %al
    outb %al, %dx
    popw %ds
    popw %dx
    popw %ax
    iretw

int10_set_cursor_position:
    cmpb $3, %bh
    jbe int10_set_cursor_position_row
    iretw
int10_set_cursor_position_row:
    cmpb $24, %dh
    jbe int10_set_cursor_position_column
    iretw
int10_set_cursor_position_column:
    cmpb $79, %dl
    jbe int10_set_cursor_position_valid
    iretw
int10_set_cursor_position_valid:
    pushw %ax
    pushw %bx
    pushw %si
    pushw %ds
    xorw %ax, %ax
    movw %ax, %ds
    movb %bh, %al
    shlw $1, %ax
    movw %ax, %si
    movw %dx, BDA_CURSOR(%si)
    movb %bh, %al
    cmpb BDA_ACTIVE_PAGE, %al
    jne int10_set_cursor_position_done
    call video_program_cursor
int10_set_cursor_position_done:
    popw %ds
    popw %si
    popw %bx
    popw %ax
    iretw

int10_get_cursor_position:
    cmpb $3, %bh
    jbe int10_get_cursor_position_valid
    iretw
int10_get_cursor_position_valid:
    pushw %ax
    pushw %bx
    pushw %si
    pushw %ds
    xorw %ax, %ax
    movw %ax, %ds
    movb %bh, %al
    shlw $1, %ax
    movw %ax, %si
    movw BDA_CURSOR(%si), %dx
    movw BDA_CURSOR_SHAPE, %cx
    popw %ds
    popw %si
    popw %bx
    popw %ax
    iretw

int10_select_page:
    cmpb $3, %al
    jbe int10_select_page_valid
    iretw
int10_select_page_valid:
    pushw %ax
    pushw %bx
    pushw %ds
    xorw %bx, %bx
    movw %bx, %ds
    movb %al, BDA_ACTIVE_PAGE
    movw %ax, %bx
    andw $0x00ff, %bx
    shlw $1, %bx
    shlw $1, %bx
    shlw $1, %bx
    shlw $1, %bx
    shlw $1, %bx
    shlw $1, %bx
    shlw $1, %bx
    shlw $1, %bx
    shlw $1, %bx
    shlw $1, %bx
    shlw $1, %bx
    shlw $1, %bx
    movw %bx, BDA_PAGE_OFFSET
    call video_program_start
    call video_program_cursor
    popw %ds
    popw %bx
    popw %ax
    iretw

int10_scroll_up:
    pushw %bp
    xorw %bp, %bp
    jmp int10_scroll_common
int10_scroll_down:
    pushw %bp
    movw $1, %bp
int10_scroll_common:
    pushw %ax
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %si
    pushw %di
    pushw %ds
    pushw %es
    pushw %ax
    xorw %ax, %ax
    movw %ax, %ds
    popw %ax
    movw %bp, VIDEO_DIRECTION
    cmpb $24, %ch
    ja int10_scroll_done
    cmpb $79, %cl
    ja int10_scroll_done
    cmpb $24, %dh
    ja int10_scroll_done
    cmpb $79, %dl
    ja int10_scroll_done
    cmpb %dh, %ch
    ja int10_scroll_done
    cmpb %dl, %cl
    ja int10_scroll_done
    movb %ch, VIDEO_TOP
    movb %cl, VIDEO_LEFT
    movb %dh, VIDEO_BOTTOM
    movb %dl, VIDEO_RIGHT
    movb %bh, VIDEO_ATTRIBUTE
    movb BDA_ACTIVE_PAGE, %bl
    movb %bl, VIDEO_PAGE
    movb %dh, %bl
    subb %ch, %bl
    incb %bl
    testb %al, %al
    jz int10_scroll_all
    cmpb %bl, %al
    jbe int10_scroll_lines_ready
int10_scroll_all:
    movb %bl, %al
int10_scroll_lines_ready:
    movb %al, VIDEO_LINES
    movw $0xb800, %bx
    movw %bx, %es
    movb VIDEO_ATTRIBUTE, %ah
    movb $0x20, %al
    movw %ax, %bp
    cmpw $0, VIDEO_DIRECTION
    jne int10_scroll_down_call
    call video_scroll_up_internal
    jmp int10_scroll_done
int10_scroll_down_call:
    call video_scroll_down_internal
int10_scroll_done:
    popw %es
    popw %ds
    popw %di
    popw %si
    popw %dx
    popw %cx
    popw %bx
    popw %ax
    popw %bp
    iretw

int10_read_character:
    cmpb $3, %bh
    jbe int10_read_character_valid
    iretw
int10_read_character_valid:
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %di
    pushw %ds
    pushw %es
    xorw %ax, %ax
    movw %ax, %ds
    movb %bh, %al
    call video_cursor_offset
    movw $0xb800, %ax
    movw %ax, %es
    movw %es:(%di), %ax
    popw %es
    popw %ds
    popw %di
    popw %dx
    popw %cx
    popw %bx
    iretw

int10_write_character_attribute:
    cmpb $3, %bh
    jbe int10_write_character_attribute_valid
    iretw
int10_write_character_attribute_valid:
    pushw %bp
    movw $1, %bp
    jmp int10_write_common
int10_write_character:
    cmpb $3, %bh
    jbe int10_write_character_valid
    iretw
int10_write_character_valid:
    pushw %bp
    xorw %bp, %bp
int10_write_common:
    pushw %ax
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %di
    pushw %ds
    pushw %es
    pushw %ax
    xorw %ax, %ax
    movw %ax, %ds
    popw %ax
    movw %bp, VIDEO_LINES
    movb %al, VIDEO_CHARACTER
    movb %bh, %al
    call video_cursor_offset
    movw $0xb800, %ax
    movw %ax, %es
    cmpb $0, VIDEO_LINES
    je int10_write_character_loop
    movb VIDEO_CHARACTER, %al
    movb %bl, %ah
int10_write_character_attribute_loop:
    testw %cx, %cx
    jz int10_write_done
    movw %ax, %es:(%di)
    addw $2, %di
    decw %cx
    jmp int10_write_character_attribute_loop
int10_write_character_loop:
    testw %cx, %cx
    jz int10_write_done
    movb VIDEO_CHARACTER, %al
    movb %al, %es:(%di)
    addw $2, %di
    decw %cx
    jmp int10_write_character_loop
int10_write_done:
    popw %es
    popw %ds
    popw %di
    popw %dx
    popw %cx
    popw %bx
    popw %ax
    popw %bp
    iretw

int10_teletype:
    cmpb $3, %bh
    jbe int10_teletype_valid
    iretw
int10_teletype_valid:
    pushw %ax
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %si
    pushw %di
    pushw %bp
    pushw %ds
    pushw %es
    pushw %ax
    xorw %ax, %ax
    movw %ax, %ds
    popw %ax
    movb %al, VIDEO_CHARACTER
    xorw %ax, %ax
    movb %bh, %al
    shlw $1, %ax
    movw %ax, %si
    movw BDA_CURSOR(%si), %dx
    cmpb $7, VIDEO_CHARACTER
    je int10_teletype_store
    cmpb $8, VIDEO_CHARACTER
    je int10_teletype_backspace
    cmpb $13, VIDEO_CHARACTER
    je int10_teletype_carriage_return
    cmpb $10, VIDEO_CHARACTER
    je int10_teletype_line_feed
    movb %bh, %al
    call video_offset
    movw $0xb800, %ax
    movw %ax, %es
    movb VIDEO_CHARACTER, %al
    movb %al, %es:(%di)
    incb %dl
    cmpb $80, %dl
    jb int10_teletype_store
    movb $0, %dl
    incb %dh
    jmp int10_teletype_check_scroll
int10_teletype_backspace:
    testb %dl, %dl
    jz int10_teletype_store
    decb %dl
    jmp int10_teletype_store
int10_teletype_carriage_return:
    movb $0, %dl
    jmp int10_teletype_store
int10_teletype_line_feed:
    incb %dh
int10_teletype_check_scroll:
    cmpb $25, %dh
    jb int10_teletype_store
    movb $24, %dh
    movb $0, VIDEO_TOP
    movb $0, VIDEO_LEFT
    movb $24, VIDEO_BOTTOM
    movb $79, VIDEO_RIGHT
    movb $1, VIDEO_LINES
    movb $7, VIDEO_ATTRIBUTE
    movb %bh, VIDEO_PAGE
    movw $0xb800, %ax
    movw %ax, %es
    movw $0x0720, %bp
    pushw %dx
    call video_scroll_up_internal
    popw %dx
int10_teletype_store:
    xorw %ax, %ax
    movb %bh, %al
    shlw $1, %ax
    movw %ax, %si
    movw %dx, BDA_CURSOR(%si)
    movb %bh, %al
    cmpb BDA_ACTIVE_PAGE, %al
    jne int10_teletype_done
    call video_program_cursor
int10_teletype_done:
    popw %es
    popw %ds
    popw %bp
    popw %di
    popw %si
    popw %dx
    popw %cx
    popw %bx
    popw %ax
    iretw

int10_get_mode:
    pushw %ds
    pushw %dx
    xorw %dx, %dx
    movw %dx, %ds
    movb BDA_VIDEO_MODE, %al
    movb BDA_COLUMNS, %ah
    movb BDA_ACTIVE_PAGE, %bh
    popw %dx
    popw %ds
    iretw

// Convert page AL and row/column DH:DL to a byte offset in the 16 KiB CGA
// window. DS must address the BDA. BX/CX/DX/BP are preserved; AX is scratch.
video_offset:
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %bp
    movw %dx, %bp
    xorw %bx, %bx
    movb %al, %bl
    movb $12, %cl
    shlw %cl, %bx
    movw %bp, %ax
    movb %ah, %al
    xorb %ah, %ah
    movw $160, %cx
    mulw %cx
    addw %ax, %bx
    movw %bp, %ax
    andw $0x00ff, %ax
    shlw $1, %ax
    addw %bx, %ax
    movw %ax, %di
    popw %bp
    popw %dx
    popw %cx
    popw %bx
    ret

// Convert the saved cursor for page AL to its CGA byte offset.
video_cursor_offset:
    pushw %ax
    pushw %si
    xorb %ah, %ah
    movw %ax, %si
    shlw $1, %si
    movw BDA_CURSOR(%si), %dx
    popw %si
    popw %ax
    call video_offset
    ret

// Program CRTC start address for page AL (CGA word addressing).
video_program_start:
    pushw %ax
    pushw %bx
    pushw %cx
    pushw %dx
    xorw %bx, %bx
    movb %al, %bl
    movb $11, %cl
    shlw %cl, %bx
    movw $0x03d4, %dx
    movb $0x0c, %al
    outb %al, %dx
    incw %dx
    movb %bh, %al
    outb %al, %dx
    decw %dx
    movb $0x0d, %al
    outb %al, %dx
    incw %dx
    movb %bl, %al
    outb %al, %dx
    popw %dx
    popw %cx
    popw %bx
    popw %ax
    ret

// Program the hardware cursor from the BDA position for page AL.
video_program_cursor:
    pushw %ax
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %si
    pushw %di
    call video_cursor_offset
    shrw $1, %di
    movw $0x03d4, %dx
    movb $0x0e, %al
    outb %al, %dx
    incw %dx
    movw %di, %bx
    movb %bh, %al
    outb %al, %dx
    decw %dx
    movb $0x0f, %al
    outb %al, %dx
    incw %dx
    movb %bl, %al
    outb %al, %dx
    popw %di
    popw %si
    popw %dx
    popw %cx
    popw %bx
    popw %ax
    ret

// Scroll helpers use the validated rectangle and target page in BDA scratch.
// ES is B800h and BP is the blank character/attribute word.
video_scroll_up_internal:
    movb VIDEO_TOP, %dh
    addb VIDEO_LINES, %dh
video_scroll_up_copy_row:
    cmpb VIDEO_BOTTOM, %dh
    ja video_scroll_up_blank_start
    movb VIDEO_LEFT, %dl
    movb VIDEO_PAGE, %al
    call video_offset
    movw %di, %si
    subb VIDEO_LINES, %dh
    movb VIDEO_PAGE, %al
    call video_offset
    addb VIDEO_LINES, %dh
    xorw %cx, %cx
    movb VIDEO_RIGHT, %cl
    subb VIDEO_LEFT, %cl
    incw %cx
video_scroll_up_copy_cell:
    movw %es:(%si), %ax
    movw %ax, %es:(%di)
    addw $2, %si
    addw $2, %di
    loop video_scroll_up_copy_cell
    incb %dh
    jmp video_scroll_up_copy_row
video_scroll_up_blank_start:
    movb VIDEO_BOTTOM, %dh
    subb VIDEO_LINES, %dh
    incb %dh
video_scroll_up_blank_row:
    cmpb VIDEO_BOTTOM, %dh
    jbe video_scroll_up_blank_row_valid
    jmp video_scroll_done
video_scroll_up_blank_row_valid:
    movb VIDEO_LEFT, %dl
    movb VIDEO_PAGE, %al
    call video_offset
    xorw %cx, %cx
    movb VIDEO_RIGHT, %cl
    subb VIDEO_LEFT, %cl
    incw %cx
video_scroll_up_blank_cell:
    movw %bp, %es:(%di)
    addw $2, %di
    loop video_scroll_up_blank_cell
    incb %dh
    jmp video_scroll_up_blank_row

video_scroll_down_internal:
    movb VIDEO_BOTTOM, %dh
    movb VIDEO_BOTTOM, %al
    subb VIDEO_TOP, %al
    incb %al
    cmpb VIDEO_LINES, %al
    je video_scroll_down_blank_start
    subb VIDEO_LINES, %dh
video_scroll_down_copy_row:
    cmpb VIDEO_TOP, %dh
    jb video_scroll_down_blank_start
    movb VIDEO_LEFT, %dl
    movb VIDEO_PAGE, %al
    call video_offset
    movw %di, %si
    addb VIDEO_LINES, %dh
    movb VIDEO_PAGE, %al
    call video_offset
    subb VIDEO_LINES, %dh
    xorw %cx, %cx
    movb VIDEO_RIGHT, %cl
    subb VIDEO_LEFT, %cl
    incw %cx
video_scroll_down_copy_cell:
    movw %es:(%si), %ax
    movw %ax, %es:(%di)
    addw $2, %si
    addw $2, %di
    loop video_scroll_down_copy_cell
    cmpb VIDEO_TOP, %dh
    je video_scroll_down_blank_start
    decb %dh
    jmp video_scroll_down_copy_row
video_scroll_down_blank_start:
    movb VIDEO_TOP, %dh
video_scroll_down_blank_row:
    movb VIDEO_TOP, %al
    addb VIDEO_LINES, %al
    cmpb %al, %dh
    jae video_scroll_done
    movb VIDEO_LEFT, %dl
    movb VIDEO_PAGE, %al
    call video_offset
    xorw %cx, %cx
    movb VIDEO_RIGHT, %cl
    subb VIDEO_LEFT, %cl
    incw %cx
video_scroll_down_blank_cell:
    movw %bp, %es:(%di)
    addw $2, %di
    loop video_scroll_down_blank_cell
    incb %dh
    jmp video_scroll_down_blank_row
video_scroll_done:
    ret

// INT 16h: classic XT read, peek, shift-status, and buffer-insertion services.
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
    cmpb $0x02, %ah
    je int16_shift_status
    cmpb $0x05, %ah
    je int16_insert
    movb $0x86, %ah
    orb $0x01, 6(%bp)
    jmp int16_done
int16_wait:
    sti
int16_wait_loop:
    movw BDA_KB_HEAD, %bx
    cmpw BDA_KB_TAIL, %bx
    jne int16_take
    hlt
    jmp int16_wait_loop
int16_take:
    movw 0x0400(%bx), %ax
    addw $2, %bx
    cmpw BDA_KB_END, %bx
    jb 1f
    movw BDA_KB_START, %bx
1:
    movw %bx, BDA_KB_HEAD
    andb $0xbe, 6(%bp)
    jmp int16_done
int16_check:
    movw BDA_KB_HEAD, %bx
    cmpw BDA_KB_TAIL, %bx
    je int16_empty
    movw 0x0400(%bx), %ax
    andb $0xbe, 6(%bp)
    jmp int16_done
int16_empty:
    orb $0x40, 6(%bp)
    jmp int16_done
int16_shift_status:
    movb BDA_KB_FLAGS1, %al
    andb $0xfe, 6(%bp)
    jmp int16_done
int16_insert:
    movw BDA_KB_TAIL, %bx
    movw %bx, %ax
    addw $2, %ax
    cmpw BDA_KB_END, %ax
    jb 1f
    movw BDA_KB_START, %ax
1:
    cmpw BDA_KB_HEAD, %ax
    je int16_insert_full
    movw %cx, 0x0400(%bx)
    movw %ax, BDA_KB_TAIL
    xorb %al, %al
    andb $0xfe, 6(%bp)
    jmp int16_done
int16_insert_full:
    movb $1, %al
    andb $0xfe, 6(%bp)
int16_done:
    popw %bx
    popw %ds
    popw %bp
    iretw

// INT 1Ah: get/set the 32-bit PC tick count and consume midnight rollover.
int1a_handler:
    pushw %bp
    movw %sp, %bp
    pushw %ds
    pushw %ax
    xorw %ax, %ax
    movw %ax, %ds
    popw %ax
    cmpb $0, %ah
    je int1a_get
    cmpb $1, %ah
    je int1a_set
    jmp int1a_unsupported
int1a_get:
    movw BDA_TICKS_LOW, %dx
    movw BDA_TICKS_HIGH, %cx
    movb BDA_MIDNIGHT, %al
    movb $0, BDA_MIDNIGHT
    xorb %ah, %ah
    andb $0xfe, 6(%bp)
    jmp int1a_done
int1a_set:
    movw %dx, BDA_TICKS_LOW
    movw %cx, BDA_TICKS_HIGH
    movb $0, BDA_MIDNIGHT
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

// INT 13h: writable A:/B: floppy services plus the ISA block adapter at C:.
int13_handler:
    pushw %bp
    movw %sp, %bp
    testb $0x80, %dl
    jz 1f
    jmp int13_fixed_dispatch
1:
    cmpb $0, %ah
    jne 1f
    jmp int13_reset
1:
    cmpb $1, %ah
    jne 1f
    jmp int13_status
1:
    cmpb $2, %ah
    jne 1f
    jmp int13_read
1:
    cmpb $3, %ah
    jne 1f
    jmp int13_write
1:
    cmpb $4, %ah
    jne 1f
    jmp int13_verify
1:
    cmpb $5, %ah
    jne 1f
    jmp int13_service_bad_request
1:
    cmpb $8, %ah
    jne 1f
    jmp int13_parameters
1:
    cmpb $0x15, %ah
    jne 1f
    jmp int13_disk_type
1:
    cmpb $0x16, %ah
    jne 1f
    jmp int13_media_status
1:
    movb $1, %ah
    xorb %al, %al
    movb %ah, BDA_DISK_STATUS
    orb $1, 6(%bp)
    popw %bp
    iretw

int13_fixed_dispatch:
    cmpb $0x80, %dl
    je 1f
    jmp int13_fixed_bad_request
1:
    cmpb $0, %ah
    jne 1f
    jmp int13_fixed_reset
1:
    cmpb $1, %ah
    jne 1f
    jmp int13_fixed_status
1:
    cmpb $2, %ah
    jne 1f
    jmp int13_fixed_read
1:
    cmpb $3, %ah
    jne 1f
    jmp int13_fixed_write
1:
    cmpb $4, %ah
    jne 1f
    jmp int13_fixed_verify
1:
    cmpb $8, %ah
    jne 1f
    jmp int13_fixed_parameters
1:
    cmpb $0x15, %ah
    jne 1f
    jmp int13_fixed_type
1:
    jmp int13_fixed_bad_request

int13_fixed_status:
    movb BDA_FIXED_STATUS, %ah
    testb %ah, %ah
    jz int13_fixed_success
    orb $1, 6(%bp)
    popw %bp
    iretw

int13_fixed_reset:
    movw $0x02a0, %dx
    xorb %al, %al
    outb %al, %dx
    inb %dx, %al
    cmpb $0x40, %al
    je int13_fixed_success
    jmp int13_fixed_controller_error
int13_fixed_success:
    xorw %ax, %ax
    movb %ah, BDA_FIXED_STATUS
    andb $0xfe, 6(%bp)
    popw %bp
    iretw

int13_fixed_parameters:
    call fixed_identify
    jnc 1f
    jmp int13_fixed_controller_error
1:
    xorw %cx, %cx
    movw $0x02a2, %dx
    inb %dx, %al
    movb %al, %ch
    incw %dx
    inb %dx, %al
    movb $6, %cl
    shlb %cl, %al
    movb %al, %cl
    addw $2, %dx
    inb %dx, %al
    andb $0x3f, %al
    orb %al, %cl
    decw %dx
    inb %dx, %al
    movb %al, %dh
    movb BDA_FIXED_COUNT, %dl
    xorw %bx, %bx
    xorw %ax, %ax
    movb %ah, BDA_FIXED_STATUS
    andb $0xfe, 6(%bp)
    popw %bp
    iretw

int13_fixed_type:
    call fixed_identify
    jnc 1f
    jmp int13_fixed_controller_error
1:
    movw $0x02a2, %dx
    inb %dx, %al
    movb %al, %bl
    incw %dx
    inb %dx, %al
    movb %al, %bh
    incw %bx
    incw %dx
    inb %dx, %al
    incb %al
    xorb %ah, %ah
    mulw %bx
    movw %ax, %bx
    incw %dx
    inb %dx, %al
    xorb %ah, %ah
    mulw %bx
    movw %ax, %dx
    xorw %cx, %cx
    movb $3, %ah
    movb $0, BDA_FIXED_STATUS
    andb $0xfe, 6(%bp)
    popw %bp
    iretw

int13_fixed_verify:
    call fixed_validate_request
    jnc 1f
    jmp int13_fixed_bad_request
1:
    jmp int13_fixed_success

int13_fixed_read:
    movb $0x20, %ah
    jmp int13_fixed_transfer
int13_fixed_write:
    movb $0x30, %ah
int13_fixed_transfer:
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %si
    pushw %di
    pushw %ds
    xorw %si, %si
    movw %si, %ds
    movb %al, REQ_ORIGINAL
    movb %ah, REQ_COMMAND
    movb REQ_ORIGINAL, %al
    call fixed_validate_request
    jnc 1f
    jmp int13_fixed_transfer_bad
1:

    movb %cl, %al
    andb $0x3f, %al
    movb %al, REQ_SECTOR
    movb %ch, %al
    xorb %ah, %ah
    movw %ax, FIXED_CYLINDER
    movb %cl, %al
    andb $0xc0, %al
    movb $6, %cl
    shrb %cl, %al
    movb %al, FIXED_CYLINDER+1
    movb %dh, REQ_HEAD
    movb %dl, REQ_DRIVE
    movb REQ_ORIGINAL, %al
    movb %al, REQ_COUNT

    xorw %ax, %ax
    movb REQ_COUNT, %al
    movw $512, %cx
    mulw %cx
    movw %ax, %di
    movw %es, %dx
    movb $12, %cl
    shrw %cl, %dx
    movw %es, %ax
    movb $4, %cl
    shlw %cl, %ax
    addw %bx, %ax
    adcb $0, %dl
    movw %ax, %si
    movw %di, %ax
    decw %ax
    addw %si, %ax
    jnc 1f
    jmp int13_fixed_transfer_boundary
1:

    movw $0x02a1, %dx
    xorb %al, %al
    outb %al, %dx
    incw %dx
    movb FIXED_CYLINDER, %al
    outb %al, %dx
    incw %dx
    movb FIXED_CYLINDER+1, %al
    outb %al, %dx
    incw %dx
    movb REQ_HEAD, %al
    outb %al, %dx
    incw %dx
    movb REQ_SECTOR, %al
    outb %al, %dx
    incw %dx
    movb REQ_COUNT, %al
    outb %al, %dx
    incw %dx
    movw %si, %ax
    outb %al, %dx
    incw %dx
    movb %ah, %al
    outb %al, %dx
    incw %dx
    movb %dl, %al
    // Recover the physical page computed above from the saved request state.
    movw %es, %ax
    movb $12, %cl
    shrw %cl, %ax
    movw %es, %di
    movb $4, %cl
    shlw %cl, %di
    addw %bx, %di
    adcb $0, %al
    outb %al, %dx
    movw $0x02a0, %dx
    movb REQ_COMMAND, %al
    outb %al, %dx
    inb %dx, %al
    cmpb $0x40, %al
    jne int13_fixed_transfer_error
    xorw %ax, %ax
    movb REQ_ORIGINAL, %al
    movb $0, BDA_FIXED_STATUS
    andb $0xfe, 6(%bp)
    jmp int13_fixed_transfer_done

int13_fixed_transfer_boundary:
    movb $0x09, %al
    jmp int13_fixed_transfer_error_status
int13_fixed_transfer_bad:
    movb $0x01, %al
    jmp int13_fixed_transfer_error_status
int13_fixed_transfer_error:
    testb %al, %al
    jnz int13_fixed_transfer_error_status
    movb $0x01, %al
int13_fixed_transfer_error_status:
    movb %al, %ah
    xorb %al, %al
    movb %ah, BDA_FIXED_STATUS
    orb $1, 6(%bp)
int13_fixed_transfer_done:
    popw %ds
    popw %di
    popw %si
    popw %dx
    popw %cx
    popw %bx
    popw %bp
    iretw

int13_fixed_controller_error:
    testb %al, %al
    jnz 1f
    movb $0x80, %al
1:
    movb %al, %ah
    xorb %al, %al
    movb %ah, BDA_FIXED_STATUS
    orb $1, 6(%bp)
    popw %bp
    iretw
int13_fixed_bad_request:
    movb $1, %ah
    xorb %al, %al
    movb %ah, BDA_FIXED_STATUS
    orb $1, 6(%bp)
    popw %bp
    iretw

// Issue the adapter's clean-room IDENTIFY command and return its status in AL.
fixed_identify:
    movw $0x02a1, %dx
    xorb %al, %al
    outb %al, %dx
    decw %dx
    movb $0xec, %al
    outb %al, %dx
    inb %dx, %al
    cmpb $0x40, %al
    jne 1f
    clc
    ret
1:
    stc
    ret

// Validate fixed-disk count and CHS against IDENTIFY without touching memory.
fixed_validate_request:
    testb %al, %al
    jz 9f
    pushw %ax
    pushw %bx
    pushw %cx
    pushw %dx
    movb %dh, %bl
    movb %ch, %bh
    movb %cl, %ah
    andb $0x3f, %ah
    movb %cl, %al
    andb $0xc0, %al
    movb $6, %cl
    shrb %cl, %al
    movb %al, %ch
    call fixed_identify
    jc 7f
    testb %ah, %ah
    jz 7f
    movw $0x02a5, %dx
    inb %dx, %al
    cmpb %al, %ah
    ja 7f
    decw %dx
    inb %dx, %al
    cmpb %al, %bl
    ja 7f
    movw $0x02a3, %dx
    inb %dx, %al
    cmpb %al, %ch
    ja 7f
    jb 8f
    decw %dx
    inb %dx, %al
    cmpb %al, %bh
    ja 7f
8:
    popw %dx
    popw %cx
    popw %bx
    popw %ax
    clc
    ret
7:
    popw %dx
    popw %cx
    popw %bx
    popw %ax
9:
    stc
    ret

int13_status:
    movb BDA_DISK_STATUS, %ah
    testb %ah, %ah
    jz 1f
    orb $1, 6(%bp)
    popw %bp
    iretw
1:
    andb $0xfe, 6(%bp)
    popw %bp
    iretw

int13_reset:
    call fdc_reset_and_sense
    xorw %ax, %ax
    movb %ah, BDA_DISK_STATUS
    andb $0xfe, 6(%bp)
    popw %bp
    iretw

int13_verify:
    call int13_validate_request
    jnc 1f
    jmp int13_service_bad_request
1:
    xorw %ax, %ax
    movb %ah, BDA_DISK_STATUS
    andb $0xfe, 6(%bp)
    popw %bp
    iretw

int13_parameters:
    cmpb $1, %dl
    jbe 1f
    jmp int13_service_bad_request
1:
    movb %dl, REQ_DRIVE
    call fdc_detect_geometry
    jnc 1f
    jmp int13_service_not_ready
1:
    xorw %ax, %ax
    xorw %bx, %bx
    xorw %cx, %cx
    movb DISK_GEOM_TRACKS, %ch
    decb %ch
    movb DISK_GEOM_SPT, %cl
    xorw %dx, %dx
    movb DISK_GEOM_HEADS, %dh
    decb %dh
    movb $2, %dl
    movb $0, BDA_DISK_STATUS
    andb $0xfe, 6(%bp)
    popw %bp
    iretw

int13_disk_type:
    cmpb $1, %dl
    jbe 1f
    jmp int13_service_bad_request
1:
    movb %dl, REQ_DRIVE
    movw $0x03f2, %dx
    movb REQ_DRIVE, %al
    orb $0x0c, %al
    outb %al, %dx
    movw $0x03f7, %dx
    inb %dx, %al
    testb $0x80, %al
    jz 1f
    jmp int13_service_not_ready
1:
    movb $1, %ah
    movb $0, BDA_DISK_STATUS
    andb $0xfe, 6(%bp)
    popw %bp
    iretw

int13_media_status:
    cmpb $1, %dl
    jbe 1f
    jmp int13_service_bad_request
1:
    movb %dl, REQ_DRIVE
    movw $0x03f2, %dx
    movb REQ_DRIVE, %al
    orb $0x0c, %al
    outb %al, %dx
    movw $0x03f7, %dx
    inb %dx, %al
    testb $0x80, %al
    jz 1f
    jmp int13_service_media_changed
1:
    xorw %ax, %ax
    movb %ah, BDA_DISK_STATUS
    andb $0xfe, 6(%bp)
    popw %bp
    iretw
int13_service_media_changed:
    movb $0x06, %ah
    xorb %al, %al
    movb %ah, BDA_DISK_STATUS
    orb $1, 6(%bp)
    popw %bp
    iretw
int13_service_not_ready:
    movb $0x80, %ah
    xorb %al, %al
    movb %ah, BDA_DISK_STATUS
    orb $1, 6(%bp)
    popw %bp
    iretw
int13_service_bad_request:
    movb $1, %ah
    xorb %al, %al
    movb %ah, BDA_DISK_STATUS
    orb $1, 6(%bp)
    popw %bp
    iretw

// Validate drive, count, CHS, and media against geometry discovered with
// standard FDC commands. Register inputs are preserved.
int13_validate_request:
    cmpb $1, %dl
    ja 9f
    testb %al, %al
    jz 9f
    movb %dl, REQ_DRIVE
    call fdc_detect_geometry
    jc 9f
    cmpb DISK_GEOM_TRACKS, %ch
    jae 9f
    cmpb DISK_GEOM_HEADS, %dh
    jae 9f
    movb %cl, %ah
    andb $0x3f, %ah
    jz 9f
    cmpb DISK_GEOM_SPT, %ah
    ja 9f
    clc
    ret
9:
    stc
    ret

int13_read:
    jmp int13_transfer
int13_write:
int13_transfer:
    pushw %bx
    pushw %cx
    pushw %dx
    pushw %si
    pushw %di
    pushw %ds
    xorw %si, %si
    movw %si, %ds
    movb %al, REQ_ORIGINAL
    cmpb $2, %ah
    jne 1f
    movb $0x06, REQ_COMMAND
    movb $0x46, REQ_DMA_MODE
    jmp 2f
1:
    movb $0x05, REQ_COMMAND
    movb $0x4a, REQ_DMA_MODE
2:
    movb REQ_ORIGINAL, %al
    call int13_validate_request
    jnc int13_request_valid
    jmp int13_bad_request
int13_request_valid:
    movb %al, REQ_COUNT
    movb %al, REQ_ORIGINAL
    movb %al, REQ_REMAINING
    movb %ch, REQ_CYLINDER
    movb %cl, REQ_SECTOR
    andb $0x3f, REQ_SECTOR
    movb %dh, REQ_HEAD
    movb %dl, REQ_DRIVE

    // Compute and validate the complete physical DMA window before issuing
    // any command. A BIOS request may not wrap a 64 KiB DMA page.
    xorw %ax, %ax
    movb REQ_COUNT, %al
    movw $512, %cx
    mulw %cx
    movw %ax, %di
    movw %es, %dx
    movb $12, %cl
    shrw %cl, %dx
    movw %es, %ax
    movb $4, %cl
    shlw %cl, %ax
    addw %bx, %ax
    adcb $0, %dl
    movw %ax, %si
    movw %si, REQ_DMA_OFFSET
    movb %dl, REQ_DMA_PAGE
    movw %di, %ax
    decw %ax
    addw %si, %ax
    jnc int13_dma_window_valid
    jmp int13_dma_boundary
int13_dma_window_valid:

int13_sector_loop:
    // One sector per controller command naturally spans track/head boundaries
    // while keeping every DMA transfer and result independently qualified.

    movb $0x06, %al
    outb %al, $0x0a
    xorb %al, %al
    outb %al, $0x0c
    movw REQ_DMA_OFFSET, %ax
    outb %al, $0x04
    movb %ah, %al
    outb %al, $0x04
    movw $511, %ax
    outb %al, $0x05
    movb %ah, %al
    outb %al, $0x05
    movb REQ_DMA_PAGE, %al
    outb %al, $0x81
    movb REQ_DMA_MODE, %al
    outb %al, $0x0b
    movb $0x02, %al
    outb %al, $0x0a

    movb $0, FDC_DONE
    movw $0x03f2, %dx
    movb REQ_DRIVE, %al
    orb $0x0c, %al
    outb %al, %dx
    movw $0x03f5, %dx
    movb REQ_COMMAND, %al
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
    movb REQ_SECTOR, %al
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

    decb REQ_REMAINING
    jz int13_read_success
    addw $512, REQ_DMA_OFFSET
    incb REQ_SECTOR
    movb REQ_SECTOR, %al
    cmpb DISK_GEOM_SPT, %al
    ja 1f
    jmp int13_sector_loop
1:
    movb $1, REQ_SECTOR
    incb REQ_HEAD
    movb REQ_HEAD, %al
    cmpb DISK_GEOM_HEADS, %al
    jae 1f
    jmp int13_sector_loop
1:
    movb $0, REQ_HEAD
    incb REQ_CYLINDER
    movb REQ_CYLINDER, %al
    cmpb DISK_GEOM_TRACKS, %al
    jae 1f
    jmp int13_sector_loop
1:
    jmp int13_bad_request

int13_read_success:
    xorw %ax, %ax
    movb REQ_ORIGINAL, %al
    movb $0, BDA_DISK_STATUS
    andb $0xfe, 6(%bp)
    jmp int13_read_done

int13_bad_request:
    movb $1, %ah
    xorb %al, %al
    movb %ah, BDA_DISK_STATUS
    orb $1, 6(%bp)
    jmp int13_read_done
int13_dma_boundary:
    movb $0x09, %ah
    xorb %al, %al
    movb %ah, BDA_DISK_STATUS
    orb $1, 6(%bp)
    jmp int13_read_done
int13_read_error:
    movb $0x20, %ah
    xorb %al, %al
    movb %ah, BDA_DISK_STATUS
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
    .asciz "Sector Zero BIOS 1.0 - POST PASS"
failure_message:
    .asciz "Sector Zero BIOS 1.0 - POST FAIL"
boot_read_failure_message:
    .asciz " - BOOT READ FAIL"
boot_signature_failure_message:
    .asciz " - BOOT SIGNATURE FAIL"

// XT scan-code set 1 translation tables. Modifier handling and buffer logic
// live above; these are data only and are not shared with diagnostic firmware.
scan_code_ascii:
    .byte 0, 27, '1', '2', '3', '4', '5', '6'
    .byte '7', '8', '9', '0', '-', '=', 8, 9
    .byte 'q', 'w', 'e', 'r', 't', 'y', 'u', 'i'
    .byte 'o', 'p', '[', ']', 13, 0, 'a', 's'
    .byte 'd', 'f', 'g', 'h', 'j', 'k', 'l', ';'
    .byte '\'', '`', 0, '\\', 'z', 'x', 'c', 'v'
    .byte 'b', 'n', 'm', ',', '.', '/', 0, '*'
    .byte 0, ' ', 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0
scan_code_shifted:
    .byte 0, 27, '!', '@', '#', '$', '%', '^'
    .byte '&', '*', '(', ')', '_', '+', 8, 0
    .byte 'Q', 'W', 'E', 'R', 'T', 'Y', 'U', 'I'
    .byte 'O', 'P', '{', '}', 13, 0, 'A', 'S'
    .byte 'D', 'F', 'G', 'H', 'J', 'K', 'L', ':'
    .byte '"', '~', 0, '|', 'Z', 'X', 'C', 'V'
    .byte 'B', 'N', 'M', '<', '>', '?', 0, '*'
    .byte 0, ' ', 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0, 0, 0, 0, 0
    .byte 0, 0, 0, 0
scan_code_numeric:
    .fill 0x47, 1, 0
    .byte '7', '8', '9', '-', '4', '5', '6', '+'
    .byte '1', '2', '3', '0', '.'

bios_version_string:
    .asciz "Sector Zero System BIOS 1.0"

    // The build stamps this byte so the unsigned sum of the declared 64 KiB
    // ROM region is zero, following the conventional PC option-ROM rule.
    .org 0xffef
bios_checksum:
    .byte 0
    .org 0xfff0
reset_vector:
    ljmp $0xf000, $bios_entry
    .ascii "07/14/26"
    .byte 0
    .byte 0xff
    .byte 0
