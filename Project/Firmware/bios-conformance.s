// Sector Zero M59 bootable BIOS conformance image.
// This guest uses BIOS interrupts exclusively; port E9h is its only direct I/O.

    .code16
    .section __TEXT,__text
    .include "diagnostic-protocol.inc"

    .ifndef FORCE_CONFORMANCE_FAILURE
    .set FORCE_CONFORMANCE_FAILURE, 0
    .endif

    .set SUITE_LOADER,      0x20
    .set SUITE_CONFORMANCE, 0x21

stage1:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7c00, %sp
    DIAG_EVENT SUITE_LOADER, 0x00, DIAG_STATUS_STARTED
    movw $0x0204, %ax
    movw $0x8000, %bx
    movw $0x0002, %cx
    xorw %dx, %dx
    int $0x13
    jc stage1_failed
    DIAG_EVENT SUITE_LOADER, 0x01, DIAG_STATUS_PASSED
    DIAG_EVENT SUITE_LOADER, DIAG_SUITE_COMPLETE, DIAG_STATUS_PASSED
    ljmp $0x0000, $0x8000
stage1_failed:
    DIAG_EVENT SUITE_LOADER, 0x01, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_LOADER, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    hlt

    .org 510
    .byte 0x55, 0xaa

    .org 512
stage2:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7c00, %sp
    DIAG_EVENT SUITE_CONFORMANCE, 0x00, DIAG_STATUS_STARTED

    // Firmware-owned IVT endpoints and canonical BDA platform identity.
    cmpw $0xf000, 0x0042
    je 1f
    jmp fail_foundation
1:
    cmpw $0xf000, 0x004e
    je 1f
    jmp fail_foundation
1:
    cmpw $0xf000, 0x005a
    je 1f
    jmp fail_foundation
1:
    cmpw $0xf000, 0x006a
    je 1f
    jmp fail_foundation
1:
    cmpw $640, 0x0413
    je 1f
    jmp fail_foundation
1:
    cmpb $3, 0x0449
    je 1f
    jmp fail_foundation
1:
    DIAG_EVENT SUITE_CONFORMANCE, 0x01, DIAG_STATUS_PASSED

    // Installed text video contract.
    movw $0x0f00, %ax
    int $0x10
    cmpb $3, %al
    je 1f
    jmp fail_video
1:
    cmpb $80, %ah
    je 1f
    jmp fail_video
1:
    DIAG_EVENT SUITE_CONFORMANCE, 0x02, DIAG_STATUS_PASSED

    int $0x11
    cmpw $0x0021, %ax
    je 1f
    jmp fail_platform
1:
    int $0x12
    cmpw $640, %ax
    je 1f
    jmp fail_platform
1:
    movw $0x8800, %ax
    int $0x15
    jnc 1f
    jmp fail_platform
1:
    testw %ax, %ax
    je 1f
    jmp fail_platform
1:
    DIAG_EVENT SUITE_CONFORMANCE, 0x03, DIAG_STATUS_PASSED

    // The mounted conformance image is a 1.44 MB, 80x2x18 floppy.
    movw $0x0800, %ax
    xorw %dx, %dx
    int $0x13
    jnc 1f
    jmp fail_disk
1:
    cmpb $79, %ch
    je 1f
    jmp fail_disk
1:
    movb %cl, %al
    andb $0x3f, %al
    cmpb $18, %al
    je 1f
    jmp fail_disk
1:
    cmpb $1, %dh
    je 1f
    jmp fail_disk
1:
    DIAG_EVENT SUITE_CONFORMANCE, 0x04, DIAG_STATUS_PASSED

    movw $0x0200, %ax
    int $0x16
    testb $0x0f, %al
    jz 1f
    jmp fail_keyboard
1:
    DIAG_EVENT SUITE_CONFORMANCE, 0x05, DIAG_STATUS_PASSED

    xorw %ax, %ax
    int $0x1a
    jnc 1f
    jmp fail_clock
1:
    DIAG_EVENT SUITE_CONFORMANCE, 0x06, DIAG_STATUS_PASSED

    .if FORCE_CONFORMANCE_FAILURE
    jmp fail_injected
    .endif

    DIAG_EVENT SUITE_CONFORMANCE, DIAG_SUITE_COMPLETE, DIAG_STATUS_PASSED
    movb $' ', %al
    call teletype
    movb $'B', %al
    call teletype
    movb $'I', %al
    call teletype
    movb $'O', %al
    call teletype
    movb $'S', %al
    call teletype
    movb $' ', %al
    call teletype
    movb $'C', %al
    call teletype
    movb $'O', %al
    call teletype
    movb $'N', %al
    call teletype
    movb $'F', %al
    call teletype
    movb $'O', %al
    call teletype
    movb $'R', %al
    call teletype
    movb $'M', %al
    call teletype
    movb $'A', %al
    call teletype
    movb $'N', %al
    call teletype
    movb $'C', %al
    call teletype
    movb $'E', %al
    call teletype
    movb $' ', %al
    call teletype
    movb $'P', %al
    call teletype
    movb $'A', %al
    call teletype
    movb $'S', %al
    call teletype
    movb $'S', %al
    call teletype
conformance_halt:
    cli
    hlt
    jmp conformance_halt

teletype:
    pushw %ax
    pushw %bx
    movb $0x0e, %ah
    xorw %bx, %bx
    int $0x10
    popw %bx
    popw %ax
    ret

fail_foundation:
    movb $0x01, %bl
    jmp conformance_failed
fail_video:
    movb $0x02, %bl
    jmp conformance_failed
fail_platform:
    movb $0x03, %bl
    jmp conformance_failed
fail_disk:
    movb $0x04, %bl
    jmp conformance_failed
fail_keyboard:
    movb $0x05, %bl
    jmp conformance_failed
fail_clock:
    movb $0x06, %bl
    jmp conformance_failed
fail_injected:
    movb $0x7f, %bl
conformance_failed:
    // The failing case is emitted explicitly for each supported failure path;
    // BL remains available to a debugger as additional detail.
    DIAG_EVENT SUITE_CONFORMANCE, 0x7f, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_CONFORMANCE, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    jmp conformance_halt

    .org 1474559
    .byte 0
