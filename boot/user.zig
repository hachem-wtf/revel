// int 0x80 syscall gate + handlers. ring 3 entry itself lives in sched.zig
// see: https://wiki.osdev.org/System_Calls

const serial = @import("serial.zig");
const idt = @import("idt.zig");
const sched = @import("sched.zig");
const regs = @import("regs.zig");
const bridge = @import("bridge");
const Frame = regs.Frame;

// scratch for a filename copied out of the caller. one static buffer is fine,
// syscalls run one at a time (if=0)
var name_buf: [64]u8 = undefined;
fn userName(ptr: u64) []const u8 {
    const p: [*]const u8 = @ptrFromInt(ptr);
    var i: usize = 0;
    while (i < name_buf.len - 1 and p[i] != 0) : (i += 1) name_buf[i] = p[i];
    return name_buf[0..i];
}

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
            sched.exitCurrent();
            asm volatile ("sti");
            while (true) asm volatile ("hlt");
        },
        1 => { // write(ptr, len): rdi = user pointer, rsi = length
            const len = frame.rsi;
            if (len > 0 and len <= 4096) {
                const bytes: [*]const u8 = @ptrFromInt(frame.rdi);
                serial.write(bytes[0..len]);
            }
            frame.rax = len; // syscall return value
        },
        2 => { // read(): return a buffered byte, else block for one
            if (sched.readReady()) |byte| {
                frame.rax = byte;
                return;
            }
            const resume_frame: Frame = .{
                .r15 = frame.r15,
                .r14 = frame.r14,
                .r13 = frame.r13,
                .r12 = frame.r12,
                .r11 = frame.r11,
                .r10 = frame.r10,
                .r9 = frame.r9,
                .r8 = frame.r8,
                .rbp = frame.rbp,
                .rdi = frame.rdi,
                .rsi = frame.rsi,
                .rdx = frame.rdx,
                .rcx = frame.rcx,
                .rbx = frame.rbx,
                .rax = frame.rax,
                .vector = 0,
                .error_code = 0,
                .rip = frame.rip,
                .cs = frame.cs,
                .rflags = frame.rflags,
                .rsp = frame.rsp,
                .ss = frame.ss,
            };
            sched.blockCurrentOnRead(resume_frame);
            asm volatile ("sti");
            while (true) asm volatile ("hlt");
        },
        4 => { // fs_size(name_ptr): returns size (like obv), or -1
            frame.rax = @bitCast(bridge.fsSize(userName(frame.rdi)));
        },
        5 => { // fs_read(name_ptr, offset, buf_ptr, len): returns bytes read
            const len = @min(frame.rcx, 4096);
            const name = userName(frame.rdi);
            const dst: [*]u8 = @ptrFromInt(frame.rdx);
            frame.rax = bridge.fsReadInto(name, frame.rsi, dst[0..len]);
        },
        else => serial.write("[syscall] unknown\r\n"),
    }
}
