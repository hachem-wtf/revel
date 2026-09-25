// the syscall boundary (int 0x80). ring 3 entry itself now lives in the
// scheduler (boot/sched.zig), which iretqs into tasks, this file is just the
// syscall gate + handlers
//
// see: https://wiki.osdev.org/System_Calls

const serial = @import("serial.zig");
const idt = @import("idt.zig");
const sched = @import("sched.zig");
const regs = @import("regs.zig");
const Frame = regs.Frame;

// what the syscall stub leaves on the stack: the gp regs it pushed, then the
// frame the cpu pushed on int 0x80. rax holds the syscall number in, and the
// handler writes the return value back into it (restored by the stubs pop)
pub const SyscallFrame = extern struct {
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
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// install the int 0x80 gate at dpl 3 so ring3 code is allowed to invoke it
pub fn installSyscall() void {
    idt.setGate(0x80, @intFromPtr(&syscallStub), 3, 1); // ist1: big stack for vm calls
}

// save gp regs, hand the frame to the zig handler, restore, iretq. the handler
// returns via syscallframe.rax (restored by the pop below), exit() never returns
export fn syscallStub() callconv(.naked) void {
    asm volatile (regs.PUSH_GPRS ++
            \\
            \\ mov %rsp, %rdi
            \\ call syscallHandler
            \\
        ++ regs.POP_GPRS ++
            \\
            \\ iretq
    );
}

export fn syscallHandler(frame: *SyscallFrame) callconv(.c) void {
    switch (frame.rax) {
        0 => { // exit(code): code in rdi
            sched.exitCurrent(); // mark dead, the next tick reclaims + switches away
            asm volatile ("sti");
            while (true) asm volatile ("hlt"); // never returns to this task
        },
        1 => { // write(ptr, len): rdi = user pointer, rsi = length
            const len = frame.rsi;
            // the processs address space is active during the syscall, so the
            // kernel can read the user pointer directly. cap the length so a
            // bogus arg cant run us off into unmapped memory
            if (len > 0 and len <= 4096) {
                const bytes: [*]const u8 = @ptrFromInt(frame.rdi);
                serial.write(bytes[0..len]); // mirrored -> kernel tasks on_tick renders it
            }
            frame.rax = len; // syscall return value
        },
        2 => { // read(): return a buffered byte, else block for one
            // become the foreground reader, if a byte is already queued, take it
            if (sched.readReady()) |byte| {
                frame.rax = byte;
                return;
            }
            // otherwise save a context that resumes right after this int 0x80
            // (with rax = the delivered byte), mark the task blocked, and yield
            // the kernel task decodes keys and calls sched.deliverinput to wake us
            const resume_frame: Frame = .{
                .r15 = frame.r15, .r14 = frame.r14, .r13 = frame.r13, .r12 = frame.r12,
                .r11 = frame.r11, .r10 = frame.r10, .r9 = frame.r9,   .r8 = frame.r8,
                .rbp = frame.rbp, .rdi = frame.rdi, .rsi = frame.rsi, .rdx = frame.rdx,
                .rcx = frame.rcx, .rbx = frame.rbx, .rax = frame.rax,
                .vector = 0, .error_code = 0,
                .rip = frame.rip, .cs = frame.cs, .rflags = frame.rflags,
                .rsp = frame.rsp, .ss = frame.ss,
            };
            sched.blockCurrentOnRead(resume_frame);
            asm volatile ("sti");
            while (true) asm volatile ("hlt"); // yield, resumed via rf when input arrives
        },
        else => serial.write("[syscall] unknown\r\n"),
    }
}
