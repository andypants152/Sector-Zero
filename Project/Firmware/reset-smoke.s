// Sector Zero M54 reset smoke ROM.
// Assemble as a 512-byte, top-aligned ROM at F000:FE00.

    .code16
    .section __TEXT,__text
    .include "diagnostic-protocol.inc"

    .ifndef FORCE_ROM_WRITE
    .set FORCE_ROM_WRITE, 0
    .endif

    .set SUITE_RESET, 0x01

    .globl _start
_start:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7000, %sp

    DIAG_EVENT SUITE_RESET, 0x00, DIAG_STATUS_STARTED
    DIAG_EVENT SUITE_RESET, 0x01, DIAG_STATUS_PASSED

    // Segment registers must accept and report the zero selectors used by
    // PC firmware before any conventional-memory initialization.
    pushw %ds
    popw %ax
    testw %ax, %ax
    jz 1f
    jmp segment_failed
1:
    pushw %es
    popw %ax
    testw %ax, %ax
    jz 1f
    jmp segment_failed
1:
    pushw %ss
    popw %ax
    testw %ax, %ax
    jz 1f
    jmp segment_failed
1:
    DIAG_EVENT SUITE_RESET, 0x02, DIAG_STATUS_PASSED

    // Exercise the real stack rather than only checking SP.
    movw $0xa55a, %ax
    pushw %ax
    xorw %ax, %ax
    popw %ax
    cmpw $0xa55a, %ax
    je 1f
    jmp stack_failed
1:
    cmpw $0x7000, %sp
    je 1f
    jmp stack_failed
1:
    DIAG_EVENT SUITE_RESET, 0x03, DIAG_STATUS_PASSED

    // Use two patterns so stuck-high and stuck-low RAM errors are visible.
    movw $0x55aa, 0x0500
    movw $0xaa55, 0x0502
    cmpw $0x55aa, 0x0500
    je 1f
    jmp ram_failed
1:
    cmpw $0xaa55, 0x0502
    je 1f
    jmp ram_failed
1:
    DIAG_EVENT SUITE_RESET, 0x04, DIAG_STATUS_PASSED

    .if FORCE_ROM_WRITE
    DIAG_EVENT SUITE_RESET, 0x05, DIAG_STATUS_STARTED
    movb $0x00, %cs:0xfe00
    // A conforming machine stops on the write; reaching this is failure.
    DIAG_EVENT SUITE_RESET, 0x05, DIAG_STATUS_FAILED
    .else
    DIAG_EVENT SUITE_RESET, 0x05, DIAG_STATUS_SKIPPED
    .endif

    DIAG_EVENT SUITE_RESET, 0x06, DIAG_STATUS_PASSED
    DIAG_EVENT SUITE_RESET, DIAG_SUITE_COMPLETE, DIAG_STATUS_PASSED
halt_forever:
    hlt
    jmp halt_forever

segment_failed:
    DIAG_EVENT SUITE_RESET, 0x02, DIAG_STATUS_FAILED
    jmp failed
stack_failed:
    DIAG_EVENT SUITE_RESET, 0x03, DIAG_STATUS_FAILED
    jmp failed
ram_failed:
    DIAG_EVENT SUITE_RESET, 0x04, DIAG_STATUS_FAILED
failed:
    DIAG_EVENT SUITE_RESET, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    jmp halt_forever

    .org 0x1f0
reset_vector:
    ljmp $0xf000, $0xfe00
    .fill 11, 1, 0xf4
