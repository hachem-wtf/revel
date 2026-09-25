pub const Frame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    // pushed by the cpu on the interrupt (long mode always pushes ss:rsp):
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// push/pop the 15 gprs in frames exact order (rax pushed first -> highest field,
// r15 last -> at rsp = &frame). shared by every save/restore stub so they cant
// drift from the frame layout above. `mov %rsp, %rdi` after push_gprs hands the
// handler a *frame
pub const PUSH_GPRS =
    \\push %rax
    \\push %rbx
    \\push %rcx
    \\push %rdx
    \\push %rsi
    \\push %rdi
    \\push %rbp
    \\push %r8
    \\push %r9
    \\push %r10
    \\push %r11
    \\push %r12
    \\push %r13
    \\push %r14
    \\push %r15
;
pub const POP_GPRS =
    \\pop %r15
    \\pop %r14
    \\pop %r13
    \\pop %r12
    \\pop %r11
    \\pop %r10
    \\pop %r9
    \\pop %r8
    \\pop %rbp
    \\pop %rdi
    \\pop %rsi
    \\pop %rdx
    \\pop %rcx
    \\pop %rbx
    \\pop %rax
;
