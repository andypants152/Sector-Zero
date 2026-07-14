// Sector Zero guest diagnostic event protocol.
// DIAG_EVENT clobbers AL and emits: signature, suite, case, status.

    .set DIAG_SIGNATURE,       0x53
    .set DIAG_STATUS_STARTED,  0x00
    .set DIAG_STATUS_PASSED,   0x01
    .set DIAG_STATUS_FAILED,   0x02
    .set DIAG_STATUS_SKIPPED,  0x03
    .set DIAG_SUITE_COMPLETE,  0xff

    .macro DIAG_EVENT suite, test_case, status
    movb $DIAG_SIGNATURE, %al
    outb %al, $0xe9
    movb $\suite, %al
    outb %al, $0xe9
    movb $\test_case, %al
    outb %al, $0xe9
    movb $\status, %al
    outb %al, $0xe9
    .endm
