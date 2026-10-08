// int 0x80 syscall gate + handlers. ring 3 entry itself lives in sched.zig
// see: https://wiki.osdev.org/System_Calls

const serial = @import("serial.zig");
const idt = @import("idt.zig");
const sched = @import("sched.zig");
const regs = @import("regs.zig");
const bridge = @import("bridge");
const Frame = regs.Frame;

// what a syscall returns in rax on failure
const SYS_ERR: u64 = @bitCast(@as(i64, -1));

// open() flags (linux values lmao)
const O_CREAT: u64 = 0x40;
const O_TRUNC: u64 = 0x200;
const O_APPEND: u64 = 0x400;

// scratch for a filename copied out of the caller
// legit one static buffer is fine
var name_buf: [128]u8 = undefined;
fn userName(ptr: u64) []const u8 {
    const p: [*]const u8 = @ptrFromInt(ptr);
    var i: usize = 0;
    while (i < name_buf.len - 1 and p[i] != 0) : (i += 1) name_buf[i] = p[i];
    return name_buf[0..i];
}

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

// 1- save gp regs
// 2- hand the frame to the zig handler
// 3- restore
// 4- iretq
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
    // i js reorganized half of these so if anyone wrote code in asm
    // for this (me), your syscalled are fucked
    switch (frame.rax) {
        0 => { // exit(code): code in rdi
            sched.exitCurrent();
            asm volatile ("sti");
            while (true) asm volatile ("hlt");
        },
        1 => { // write(fd, ptr, len)
            const len = frame.rdx;
            if (sched.fdGet(@bitCast(frame.rdi))) |f| {
                if (f.kind == .console) {
                    if (len > 0 and len <= 4096) {
                        const bytes: [*]const u8 = @ptrFromInt(frame.rsi);
                        serial.write(bytes[0..len]);
                    }
                    frame.rax = len;
                } else if (f.kind == .file) {
                    const n = @min(len, 4096);
                    const src: [*]const u8 = @ptrFromInt(frame.rsi);
                    if (bridge.fsWriteAt(f.path[0..f.path_len], f.offset, src[0..n])) {
                        f.offset += n;
                        frame.rax = n;
                    } else frame.rax = SYS_ERR;
                } else {
                    frame.rax = SYS_ERR; // keyboard isnt writable
                }
            } else frame.rax = SYS_ERR;
        },
        2 => { // read(fd, buf, count)
            const count = frame.rdx;
            const f = sched.fdGet(@bitCast(frame.rdi)) orelse {
                frame.rax = SYS_ERR;
                return;
            };
            switch (f.kind) {
                .keyboard => {
                    if (count == 0) {
                        frame.rax = 0;
                        return;
                    }
                    if (sched.readReady()) |byte| {
                        const dst: [*]u8 = @ptrFromInt(frame.rsi);
                        dst[0] = byte;
                        frame.rax = 1;
                        return;
                    }
                    // nothn buffered
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
                        .rip = frame.rip - 2,
                        .cs = frame.cs,
                        .rflags = frame.rflags,
                        .rsp = frame.rsp,
                        .ss = frame.ss,
                    };
                    sched.blockCurrentOnRead(resume_frame);
                    asm volatile ("sti");
                    while (true) asm volatile ("hlt");
                },
                .file => {
                    const n = @min(count, 4096);
                    const dst: [*]u8 = @ptrFromInt(frame.rsi);
                    const got = bridge.fsReadInto(f.path[0..f.path_len], f.offset, dst[0..n]);
                    f.offset += got;
                    frame.rax = got;
                },
                else => frame.rax = SYS_ERR,
            }
        },
        7 => { // open(path_ptr, flags)
            const name = userName(frame.rdi);
            const flags = frame.rsi;
            var size = bridge.fsSize(name);
            if (size < 0) {
                if (flags & O_CREAT != 0 and bridge.fsStore(name, "")) {
                    size = 0;
                } else {
                    frame.rax = SYS_ERR;
                    return;
                }
            } else if (flags & O_TRUNC != 0) {
                _ = bridge.fsStore(name, "");
                size = 0;
            }
            const fd = sched.fdOpen(name);
            if (fd < 0) {
                frame.rax = SYS_ERR;
                return;
            }
            if (flags & O_APPEND != 0) {
                if (sched.fdGet(fd)) |f| f.offset = @intCast(size);
            }
            frame.rax = @bitCast(fd);
        },
        8 => { // close(fd)
            frame.rax = @bitCast(sched.fdClose(@bitCast(frame.rdi)));
        },
        9 => { // lseek(fd, offset, whence)
            if (sched.fdGet(@bitCast(frame.rdi))) |f| {
                switch (frame.rdx) {
                    0 => f.offset = frame.rsi, // SEEK_SET
                    1 => f.offset += frame.rsi, // SEEK_CUR
                    2 => { // SEEK_END
                        const sz = bridge.fsSize(f.path[0..f.path_len]);
                        if (sz >= 0) f.offset = @as(u64, @intCast(sz)) +% frame.rsi;
                    },
                    else => {},
                }
                frame.rax = f.offset;
            } else frame.rax = SYS_ERR;
        },
        4 => { // fs_size(name_ptr)
            frame.rax = @bitCast(bridge.fsSize(userName(frame.rdi)));
        },
        5 => { // fs_read(name_ptr, offset, buf_ptr, len)
            const len = @min(frame.rcx, 4096);
            const name = userName(frame.rdi);
            const dst: [*]u8 = @ptrFromInt(frame.rdx);
            frame.rax = bridge.fsReadInto(name, frame.rsi, dst[0..len]);
        },
        6 => { // fs_write(name_ptr, buf_ptr, len)
            const len = @min(frame.rdx, 64 * 1024);
            const name = userName(frame.rdi);
            const src: [*]const u8 = @ptrFromInt(frame.rsi);
            frame.rax = if (bridge.fsStore(name, src[0..len])) 1 else 0;
        },
        else => serial.write("[syscall] unknown\r\n"),
    }
}
