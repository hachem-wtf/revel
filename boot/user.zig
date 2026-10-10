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

// syscall numbers
const SYS_EXIT: u64 = 0;
const SYS_WRITE: u64 = 1;
const SYS_READ: u64 = 2;
const SYS_FS_SIZE: u64 = 4;
const SYS_FS_READ: u64 = 5;
const SYS_FS_WRITE: u64 = 6;
const SYS_OPEN: u64 = 7;
const SYS_CLOSE: u64 = 8;
const SYS_LSEEK: u64 = 9;
const SYS_BRK: u64 = 10;
const SYS_SBRK: u64 = 11;

// lseek whence
const SEEK_SET: u64 = 0;
const SEEK_CUR: u64 = 1;
const SEEK_END: u64 = 2;

const SYSCALL_VECTOR: u8 = 0x80; // the int vector ring 3 traps through
const INT80_LEN: u64 = 2; // length of the int 0x80 instruction, i use this to rewind rip
const MAX_IO: u64 = 4096; // clamp on a single read/write
const MAX_FS_WRITE: u64 = 64 * 1024; // clamp on a whole file write
const MAX_NAME = 128;

// scratch for a filename copied out of the caller
// legit one static buffer is fine
var name_buf: [MAX_NAME]u8 = undefined;
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
    idt.setGate(SYSCALL_VECTOR, @intFromPtr(&syscallStub), 3, 1); // ist1: big stack for vm calls
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
        SYS_EXIT => { // exit(code): code in rdi
            sched.exitCurrent();
            asm volatile ("sti");
            while (true) asm volatile ("hlt");
        },
        SYS_WRITE => { // write(fd, ptr, len)
            const len = frame.rdx;
            if (sched.fdGet(@bitCast(frame.rdi))) |descriptor| {
                if (descriptor.kind == .console) {
                    if (len > 0 and len <= MAX_IO) {
                        const bytes: [*]const u8 = @ptrFromInt(frame.rsi);
                        serial.write(bytes[0..len]);
                    }
                    frame.rax = len;
                } else if (descriptor.kind == .file) {
                    const count = @min(len, MAX_IO);
                    const src: [*]const u8 = @ptrFromInt(frame.rsi);
                    if (bridge.fsWriteAt(descriptor.path[0..descriptor.path_len], descriptor.offset, src[0..count])) {
                        descriptor.offset += count;
                        frame.rax = count;
                    } else frame.rax = SYS_ERR;
                } else {
                    frame.rax = SYS_ERR; // keyboard isnt writable
                }
            } else frame.rax = SYS_ERR;
        },
        SYS_READ => { // read(fd, buf, count)
            const count = frame.rdx;
            const descriptor = sched.fdGet(@bitCast(frame.rdi)) orelse {
                frame.rax = SYS_ERR;
                return;
            };
            switch (descriptor.kind) {
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
                        .rip = frame.rip - INT80_LEN,
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
                    const clamped = @min(count, MAX_IO);
                    const dst: [*]u8 = @ptrFromInt(frame.rsi);
                    const got = bridge.fsReadInto(descriptor.path[0..descriptor.path_len], descriptor.offset, dst[0..clamped]);
                    descriptor.offset += got;
                    frame.rax = got;
                },
                else => frame.rax = SYS_ERR,
            }
        },
        SYS_OPEN => { // open(path_ptr, flags)
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
                if (sched.fdGet(fd)) |descriptor| descriptor.offset = @intCast(size);
            }
            frame.rax = @bitCast(fd);
        },
        SYS_CLOSE => { // close(fd)
            frame.rax = @bitCast(sched.fdClose(@bitCast(frame.rdi)));
        },
        SYS_LSEEK => { // lseek(fd, offset, whence)
            if (sched.fdGet(@bitCast(frame.rdi))) |descriptor| {
                switch (frame.rdx) {
                    SEEK_SET => descriptor.offset = frame.rsi, // SEEK_SET
                    SEEK_CUR => descriptor.offset += frame.rsi, // SEEK_CUR
                    SEEK_END => {
                        const sz = bridge.fsSize(descriptor.path[0..descriptor.path_len]);
                        if (sz >= 0) descriptor.offset = @as(u64, @intCast(sz)) +% frame.rsi;
                    },
                    else => {},
                }
                frame.rax = descriptor.offset;
            } else frame.rax = SYS_ERR;
        },
        SYS_FS_SIZE => { // fs_size(name_ptr)
            frame.rax = @bitCast(bridge.fsSize(userName(frame.rdi)));
        },
        SYS_FS_READ => { // fs_read(name_ptr, offset, buf_ptr, len)
            const len = @min(frame.rcx, MAX_IO);
            const name = userName(frame.rdi);
            const dst: [*]u8 = @ptrFromInt(frame.rdx);
            frame.rax = bridge.fsReadInto(name, frame.rsi, dst[0..len]);
        },
        SYS_FS_WRITE => { // fs_write(name_ptr, buf_ptr, len)
            const len = @min(frame.rdx, MAX_FS_WRITE);
            const name = userName(frame.rdi);
            const src: [*]const u8 = @ptrFromInt(frame.rsi);
            frame.rax = if (bridge.fsStore(name, src[0..len])) 1 else 0;
        },
        SYS_BRK => { // brk(addr)
            frame.rax = @bitCast(sched.brk(frame.rdi));
        },
        SYS_SBRK => { // sbrk(increment)
            frame.rax = @bitCast(sched.sbrk(@bitCast(frame.rdi)));
        },
        else => serial.write("[syscall] unknown\r\n"),
    }
}
