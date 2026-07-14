// Sector Zero M55 direct-hardware platform diagnostic.
// This ROM intentionally does not call or share service code with the BIOS.

    .code16
    .section __TEXT,__text
    .include "diagnostic-protocol.inc"

    .set MODULE_SELECTOR, 0x04f0
    .set TIMER_SEEN,      0x04f1
    .set KEYBOARD_SCAN,   0x04f2
    .set FDC_DONE,        0x04f3

    .set SUITE_MEMORY,    0x10
    .set SUITE_VIDEO,     0x11
    .set SUITE_TIMER,     0x12
    .set SUITE_KEYBOARD,  0x13
    .set SUITE_STORAGE,   0x14

    .globl _start
_start:
    cli
    xorw %ax, %ax
    movw %ax, %ds
    movw %ax, %es
    movw %ax, %ss
    movw $0x7000, %sp
    movb MODULE_SELECTOR, %bl

    testb %bl, %bl
    jz run_all
    cmpb $SUITE_MEMORY, %bl
    jne 1f
    call memory_suite
    jmp diagnostic_done
1:
    cmpb $SUITE_VIDEO, %bl
    jne 1f
    call video_suite
    jmp diagnostic_done
1:
    cmpb $SUITE_TIMER, %bl
    jne 1f
    call timer_suite
    jmp diagnostic_done
1:
    cmpb $SUITE_KEYBOARD, %bl
    jne 1f
    call keyboard_suite
    jmp diagnostic_done
1:
    cmpb $SUITE_STORAGE, %bl
    jne invalid_selector
    call storage_suite
    jmp diagnostic_done

run_all:
    call memory_suite
    call video_suite
    call timer_suite
    call keyboard_suite
    call storage_suite
    jmp diagnostic_done

invalid_selector:
    DIAG_EVENT 0x00, 0x00, DIAG_STATUS_FAILED

diagnostic_done:
    cli
halt_forever:
    hlt
    jmp halt_forever

memory_suite:
    DIAG_EVENT SUITE_MEMORY, 0x00, DIAG_STATUS_STARTED
    movw $0x5aa5, 0x0500
    cmpw $0x5aa5, 0x0500
    je 1f
    DIAG_EVENT SUITE_MEMORY, 0x01, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_MEMORY, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    ret
1:
    movw $0x9000, %ax
    movw %ax, %es
    movw $0xa55a, %es:0
    cmpw $0xa55a, %es:0
    je 1f
    DIAG_EVENT SUITE_MEMORY, 0x01, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_MEMORY, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    ret
1:
    DIAG_EVENT SUITE_MEMORY, 0x01, DIAG_STATUS_PASSED
    cmpb $0xea, %cs:0xfff0
    je 1f
    DIAG_EVENT SUITE_MEMORY, 0x02, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_MEMORY, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    ret
1:
    DIAG_EVENT SUITE_MEMORY, 0x02, DIAG_STATUS_PASSED
    DIAG_EVENT SUITE_MEMORY, DIAG_SUITE_COMPLETE, DIAG_STATUS_PASSED
    ret

video_suite:
    DIAG_EVENT SUITE_VIDEO, 0x00, DIAG_STATUS_STARTED
    movw $0x03d8, %dx
    movb $0x29, %al
    outb %al, %dx
    movw $0xb800, %ax
    movw %ax, %es
    movw $0x1f53, %es:0
    movw $0x1f5a, %es:2
    cmpw $0x1f53, %es:0
    jne video_failed
    cmpw $0x1f5a, %es:2
    jne video_failed
    DIAG_EVENT SUITE_VIDEO, 0x01, DIAG_STATUS_PASSED
    DIAG_EVENT SUITE_VIDEO, DIAG_SUITE_COMPLETE, DIAG_STATUS_PASSED
    ret
video_failed:
    DIAG_EVENT SUITE_VIDEO, 0x01, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_VIDEO, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    ret

timer_suite:
    DIAG_EVENT SUITE_TIMER, 0x00, DIAG_STATUS_STARTED
    cli
    movb $0, TIMER_SEEN
    movw $timer_irq, 0x0020
    movw $0xf000, 0x0022
    movb $0x11, %al
    outb %al, $0x20
    movb $0x08, %al
    outb %al, $0x21
    movb $0x04, %al
    outb %al, $0x21
    movb $0x01, %al
    outb %al, $0x21
    movb $0xfe, %al
    outb %al, $0x21
    inb $0x21, %al
    cmpb $0xfe, %al
    jne timer_pic_failed
    DIAG_EVENT SUITE_TIMER, 0x01, DIAG_STATUS_PASSED
    movb $0x36, %al
    outb %al, $0x43
    movb $0x20, %al
    outb %al, $0x40
    xorb %al, %al
    outb %al, $0x40
    sti
    movw $0xffff, %cx
timer_wait:
    cmpb $0, TIMER_SEEN
    jne timer_passed
    loop timer_wait
    cli
    DIAG_EVENT SUITE_TIMER, 0x02, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_TIMER, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    ret
timer_passed:
    cli
    DIAG_EVENT SUITE_TIMER, 0x02, DIAG_STATUS_PASSED
    DIAG_EVENT SUITE_TIMER, DIAG_SUITE_COMPLETE, DIAG_STATUS_PASSED
    ret
timer_pic_failed:
    DIAG_EVENT SUITE_TIMER, 0x01, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_TIMER, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    ret

keyboard_suite:
    DIAG_EVENT SUITE_KEYBOARD, 0x00, DIAG_STATUS_STARTED
    cli
    movb $0, KEYBOARD_SCAN
    movw $keyboard_irq, 0x0024
    movw $0xf000, 0x0026
    movb $0x11, %al
    outb %al, $0x20
    movb $0x08, %al
    outb %al, $0x21
    movb $0x04, %al
    outb %al, $0x21
    movb $0x01, %al
    outb %al, $0x21
    movb $0xfd, %al
    outb %al, $0x21
    inb $0x61, %al
    orb $0x80, %al
    outb %al, $0x61
    andb $0x7f, %al
    outb %al, $0x61
    DIAG_EVENT SUITE_KEYBOARD, 0x01, DIAG_STATUS_STARTED
    sti
    movw $0xffff, %cx
keyboard_wait:
    cmpb $0, KEYBOARD_SCAN
    jne keyboard_received
    loop keyboard_wait
    cli
    DIAG_EVENT SUITE_KEYBOARD, 0x01, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_KEYBOARD, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    ret
keyboard_received:
    cli
    cmpb $0x1e, KEYBOARD_SCAN
    jne keyboard_bad_scan
    DIAG_EVENT SUITE_KEYBOARD, 0x01, DIAG_STATUS_PASSED
    DIAG_EVENT SUITE_KEYBOARD, DIAG_SUITE_COMPLETE, DIAG_STATUS_PASSED
    ret
keyboard_bad_scan:
    DIAG_EVENT SUITE_KEYBOARD, 0x01, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_KEYBOARD, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    ret

storage_suite:
    DIAG_EVENT SUITE_STORAGE, 0x00, DIAG_STATUS_STARTED
    movw $0x03f7, %dx
    inb %dx, %al
    testb $0x80, %al
    jz storage_media_present
    DIAG_EVENT SUITE_STORAGE, 0x01, DIAG_STATUS_SKIPPED
    DIAG_EVENT SUITE_STORAGE, DIAG_SUITE_COMPLETE, DIAG_STATUS_PASSED
    ret
storage_media_present:
    DIAG_EVENT SUITE_STORAGE, 0x01, DIAG_STATUS_PASSED
    cli
    movb $0, FDC_DONE
    // Reset the controller and consume all four sense-interrupt responses.
    movw $0x03f2, %dx
    xorb %al, %al
    outb %al, %dx
    movb $0x0c, %al
    outb %al, %dx
    movw $0x03f5, %dx
    movw $4, %cx
storage_sense:
    movb $0x08, %al
    outb %al, %dx
    inb %dx, %al
    inb %dx, %al
    loop storage_sense

    movw $fdc_irq, 0x0038
    movw $0xf000, 0x003a
    movb $0x11, %al
    outb %al, $0x20
    movb $0x08, %al
    outb %al, $0x21
    movb $0x04, %al
    outb %al, $0x21
    movb $0x01, %al
    outb %al, $0x21
    movb $0xbf, %al
    outb %al, $0x21

    // DMA channel 2: device-to-memory, one 512-byte sector at 0000:2000.
    movb $0x06, %al
    outb %al, $0x0a
    xorb %al, %al
    outb %al, $0x0c
    outb %al, $0x04
    movb $0x20, %al
    outb %al, $0x04
    movb $0xff, %al
    outb %al, $0x05
    movb $0x01, %al
    outb %al, $0x05
    xorb %al, %al
    outb %al, $0x81
    movb $0x46, %al
    outb %al, $0x0b
    movb $0x02, %al
    outb %al, $0x0a

    movw $0x03f5, %dx
    movb $0x06, %al
    outb %al, %dx
    xorb %al, %al
    outb %al, %dx
    outb %al, %dx
    outb %al, %dx
    movb $0x01, %al
    outb %al, %dx
    movb $0x02, %al
    outb %al, %dx
    movb $0x01, %al
    outb %al, %dx
    movb $0x1b, %al
    outb %al, %dx
    movb $0xff, %al
    outb %al, %dx
    sti
    movw $0xffff, %cx
storage_wait:
    cmpb $0, FDC_DONE
    jne storage_results
    loop storage_wait
    cli
    DIAG_EVENT SUITE_STORAGE, 0x02, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_STORAGE, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    ret
storage_results:
    cli
    inb %dx, %al
    movb %al, %bl
    inb %dx, %al
    orb %al, %bl
    inb %dx, %al
    orb %al, %bl
    inb %dx, %al
    inb %dx, %al
    inb %dx, %al
    inb %dx, %al
    testb %bl, %bl
    jnz storage_failed
    cmpb $0xa5, 0x2000
    jne storage_failed
    cmpb $0xa5, 0x21ff
    jne storage_failed
    DIAG_EVENT SUITE_STORAGE, 0x02, DIAG_STATUS_PASSED
    DIAG_EVENT SUITE_STORAGE, DIAG_SUITE_COMPLETE, DIAG_STATUS_PASSED
    ret
storage_failed:
    DIAG_EVENT SUITE_STORAGE, 0x02, DIAG_STATUS_FAILED
    DIAG_EVENT SUITE_STORAGE, DIAG_SUITE_COMPLETE, DIAG_STATUS_FAILED
    ret

timer_irq:
    pushw %ax
    pushw %ds
    xorw %ax, %ax
    movw %ax, %ds
    movb $1, TIMER_SEEN
    movb $0xff, %al
    outb %al, $0x21
    movb $0x20, %al
    outb %al, $0x20
    popw %ds
    popw %ax
    iretw

keyboard_irq:
    pushw %ax
    pushw %ds
    xorw %ax, %ax
    movw %ax, %ds
    inb $0x60, %al
    movb %al, KEYBOARD_SCAN
    inb $0x61, %al
    orb $0x80, %al
    outb %al, $0x61
    andb $0x7f, %al
    outb %al, $0x61
    movb $0x20, %al
    outb %al, $0x20
    popw %ds
    popw %ax
    iretw

fdc_irq:
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

    .org 0xfff0
reset_vector:
    ljmp $0xf000, $0x0000
    .fill 11, 1, 0xf4
