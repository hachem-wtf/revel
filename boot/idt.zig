// the idt is for the 32 cpu excpetion vectors, if i dont implement this,
// any fault triple-falts and the machine just fucking dies for some reason
// this just maps interupts and halts ig
//
// see: https://wiki.osdev.org/Interrupt_Descriptor_Table

const gdt = @import("gdt.zig");
const serial = @import("serial.zig");
const pic = @import("pic.zig");
const keyboard = @import("keyboard.zig");

// 64bit interrupt gate
const Gate = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8, // 0x8E = present, ring 0, 64-bit interrupt gate
    offset_mid: u16,
    offset_high: u32,
    reserved: u32,
};

const Idtr = packed struct {
    limit: u16,
    base: u64,
};

var idt = [_]Gate{@bitCast(@as(u128, 0))} ** 256;
var idtr: Idtr = undefined;

// what the common stub leaves on the stack, low address -> high.
// `mov rdi, rsp` hands the handler a pointer to this
const Frame = extern struct {
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
    // pushed by the CPU on the exception:
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

const names = [_][]const u8{
    "divide by zero",         "debug",
    "non-maskable interrupt", "breakpoint",
    "overflow",               "bound range exceeded",
    "invalid opcode",         "device not available",
    "double fault",           "coprocessor segment overrun",
    "invalid TSS",            "segment not present",
    "stack-segment fault",    "general protection fault",
    "page fault",             "reserved",
    "x87 floating-point",     "alignment check",
    "machine check",          "SIMD floating-point",
    "virtualization",         "control protection",
};

fn name(vector: u64) []const u8 {
    return if (vector < names.len) names[vector] else "unknown";
}

// only these vectors push a real error code, the rest the stub pushes a 0
// so the frame layout is uniform
fn hasErrorCode(comptime vector: u8) bool {
    return switch (vector) {
        8, 10, 11, 12, 13, 14, 17, 21 => true,
        else => false,
    };
}

// one naked (kinky) entry stub per vector, so normalise the stack (dummy error code if
// needed), push the vector number, jump to the shared save and dispatch path
fn stub(comptime vector: u8) fn () callconv(.naked) void {
    return struct {
        fn entry() callconv(.naked) void {
            if (comptime !hasErrorCode(vector)) asm volatile ("pushq $0");
            asm volatile ("pushq %[v]\n jmp isrCommon"
                :
                : [v] "i" (@as(u32, vector)),
            );
        }
    }.entry;
}

// Save the GP registers into a Frame, hand its address to the Zig handler
export fn isrCommon() callconv(.naked) void {
    asm volatile (
        \\ push %rax
        \\ push %rbx
        \\ push %rcx
        \\ push %rdx
        \\ push %rsi
        \\ push %rdi
        \\ push %rbp
        \\ push %r8
        \\ push %r9
        \\ push %r10
        \\ push %r11
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ mov %rsp, %rdi
        \\ call exceptionHandler
    );
}

fn writeHex(value: u64) void {
    const digits = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        buf[2 + i] = digits[(value >> shift) & 0xF];
    }
    serial.write(&buf);
}

export fn exceptionHandler(frame: *Frame) callconv(.c) noreturn {
    serial.write("\r\n!!! CPU DID AN OOPSIE: ");
    serial.write(name(frame.vector));
    serial.write("\r\n  vector=");
    writeHex(frame.vector);
    serial.write(" err=");
    writeHex(frame.error_code);
    serial.write("\r\n  rip=");
    writeHex(frame.rip);
    serial.write(" cs=");
    writeHex(frame.cs);
    serial.write("\r\n  rflags=");
    writeHex(frame.rflags);
    serial.write(" rsp=");
    writeHex(frame.rsp);
    // page faults stash the offending address in CR2
    if (frame.vector == 14) {
        const cr2 = asm volatile ("mov %%cr2, %[out]"
            : [out] "=r" (-> u64),
        );
        serial.write("\r\n  cr2=");
        writeHex(cr2);
    }
    serial.write("\r\n");
    while (true) asm volatile ("hlt");
}

// hardware IRQ
// unlike exceptions these must return so we acknowledge the PIC and iretq
// back to whatever we interrupted. the stub mirrors the exception one (dummy
// error code + vector for a uniform Frame) but jumps to the returning path.
fn irqStub(comptime vector: u8) fn () callconv(.naked) void {
    return struct {
        fn entry() callconv(.naked) void {
            asm volatile ("pushq $0"); // dummy error code, keeps Frame uniform
            asm volatile ("pushq %[v]\n jmp irqCommon"
                :
                : [v] "i" (@as(u32, vector)),
            );
        }
    }.entry;
}

// same register save as isrCommon, but afterwards we restore everything, drop
// the pushed vector + error code, and iretq instead of halting.
export fn irqCommon() callconv(.naked) void {
    asm volatile (
        \\ push %rax
        \\ push %rbx
        \\ push %rcx
        \\ push %rdx
        \\ push %rsi
        \\ push %rdi
        \\ push %rbp
        \\ push %r8
        \\ push %r9
        \\ push %r10
        \\ push %r11
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ mov %rsp, %rdi
        \\ call irqDispatch
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ pop %r11
        \\ pop %r10
        \\ pop %r9
        \\ pop %r8
        \\ pop %rbp
        \\ pop %rdi
        \\ pop %rsi
        \\ pop %rdx
        \\ pop %rcx
        \\ pop %rbx
        \\ pop %rax
        \\ add $16, %rsp
        \\ iretq
    );
}

export fn irqDispatch(frame: *Frame) callconv(.c) void {
    switch (frame.vector) {
        pic.MASTER_OFFSET + 1 => keyboard.onIrq(), // IRQ1: keyboard
        else => {},
    }
    pic.eoi(@intCast(frame.vector - pic.MASTER_OFFSET));
}

// dpl 0 = only ring 0 can invoke via `int`
// dpl 3 = ring 3 may (for syscalls)
pub fn setGate(vector: u8, handler: u64, dpl: u2) void {
    idt[vector] = .{
        .offset_low = @truncate(handler),
        .selector = gdt.KERNEL_CODE,
        .ist = 0,
        .type_attr = 0x8E | (@as(u8, dpl) << 5),
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
        .reserved = 0,
    };
}

// fill the exception vectors and load the IDT
pub fn init() void {
    inline for (0..32) |v| setGate(v, @intFromPtr(&stub(v)), 0);
    // IRQ1 (keyboard) -> vector 0x21
    // the PIC is remapped separately in boot.
    setGate(pic.MASTER_OFFSET + 1, @intFromPtr(&irqStub(pic.MASTER_OFFSET + 1)), 0);
    idtr = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr),
        : .{ .memory = true });
}
