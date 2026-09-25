// the idt is for the 32 cpu excpetion vectors, if i dont implement this,
// any fault triple falts and the machine just fucking dies for some reason
// this just maps interupts and halts ig
//
// see: https://wiki.osdev.org/Interrupt_Descriptor_Table

const gdt = @import("gdt.zig");
const serial = @import("serial.zig");
const pic = @import("pic.zig");
const keyboard = @import("keyboard.zig");
const timer = @import("timer.zig");
const sched = @import("sched.zig");
const regs = @import("regs.zig");
const Frame = regs.Frame;

// 64bit interrupt gate
const Gate = packed struct {
    offset_low: u16,
    selector: u16,
    ist: u8,
    type_attr: u8, // 0x8e = present, ring 0, 64 bit interrupt gate
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

// save the gp registers into a frame, hand its address to the zig handler
export fn isrCommon() callconv(.naked) void {
    asm volatile (regs.PUSH_GPRS ++
            \\
            \\ mov %rsp, %rdi
            \\ call exceptionHandler
    );
}

export fn exceptionHandler(frame: *Frame) callconv(.c) noreturn {
    serial.write("\r\n!!! CPU DID AN OOPSIE: ");
    serial.write(name(frame.vector));
    serial.write("\r\n  vector=");
    serial.writeHex(frame.vector);
    serial.write(" err=");
    serial.writeHex(frame.error_code);
    serial.write("\r\n  rip=");
    serial.writeHex(frame.rip);
    serial.write(" cs=");
    serial.writeHex(frame.cs);
    serial.write("\r\n  rflags=");
    serial.writeHex(frame.rflags);
    serial.write(" rsp=");
    serial.writeHex(frame.rsp);
    // page faults stash the offending address in cr2
    if (frame.vector == 14) {
        const cr2 = asm volatile ("mov %%cr2, %[out]"
            : [out] "=r" (-> u64),
        );
        serial.write("\r\n  cr2=");
        serial.writeHex(cr2);
    }
    serial.write("\r\n");
    while (true) asm volatile ("hlt");
}

// hardware irq
// unlike exceptions these must return so we acknowledge the pic and iretq
// back to whatever we interrupted. the stub mirrors the exception one (dummy
// error code + vector for a uniform frame) but jumps to the returning path
fn irqStub(comptime vector: u8) fn () callconv(.naked) void {
    return struct {
        fn entry() callconv(.naked) void {
            asm volatile ("pushq $0"); // dummy error code, keeps frame uniform
            asm volatile ("pushq %[v]\n jmp irqCommon"
                :
                : [v] "i" (@as(u32, vector)),
            );
        }
    }.entry;
}

// same register save as isrcommon, but afterwards we restore everything, drop
// the pushed vector + error code, and iretq instead of halting
export fn irqCommon() callconv(.naked) void {
    asm volatile (regs.PUSH_GPRS ++
            \\
            \\ mov %rsp, %rdi
            \\ call irqDispatch
            \\
        ++ regs.POP_GPRS ++
            \\
            \\ add $16, %rsp
            \\ iretq
    );
}

export fn irqDispatch(frame: *Frame) callconv(.c) void {
    switch (frame.vector) {
        pic.MASTER_OFFSET + 0 => timer.onIrq(), // irq0: pit (tick count)
        pic.MASTER_OFFSET + 1 => keyboard.onIrq(), // irq1: keyboard
        else => {},
    }
    // eoi before we possibly switch tasks (the switch never returns here)
    pic.eoi(@intCast(frame.vector - pic.MASTER_OFFSET));
    // maybe swap `frame` to another task
    if (frame.vector == pic.MASTER_OFFSET + 0) sched.tick(frame);
}

// dpl 0 = only ring 0 can invoke via `int`, dpl 3 = ring 3 may (for syscalls)
// ist 0 = use the stack the cpu would pick (rsp0 on a ring switch), ist 1..7 =
// force tss.istn, for handlers that need a known good/big stack
pub fn setGate(vector: u8, handler: u64, dpl: u2, ist: u3) void {
    idt[vector] = .{
        .offset_low = @truncate(handler),
        .selector = gdt.KERNEL_CODE,
        .ist = ist,
        .type_attr = 0x8E | (@as(u8, dpl) << 5),
        .offset_mid = @truncate(handler >> 16),
        .offset_high = @truncate(handler >> 32),
        .reserved = 0,
    };
}

// fill the exception vectors and load the idt
pub fn init() void {
    inline for (0..32) |v| setGate(v, @intFromPtr(&stub(v)), 0, 0);
    // #df (8) and #pf (14) land on ist2s fault stack, so a kernel stack overflow
    // produces a real exception dump instead of a silent triple fault
    setGate(8, @intFromPtr(&stub(8)), 0, 2);
    setGate(14, @intFromPtr(&stub(14)), 0, 2);
    // irq0 (pit) -> vector 0x20, irq1 (keyboard) -> vector 0x21
    // the pic is remapped separately in boot
    setGate(pic.MASTER_OFFSET + 0, @intFromPtr(&irqStub(pic.MASTER_OFFSET + 0)), 0, 0);
    setGate(pic.MASTER_OFFSET + 1, @intFromPtr(&irqStub(pic.MASTER_OFFSET + 1)), 0, 0);
    idtr = .{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[idtr])"
        :
        : [idtr] "r" (&idtr),
        : .{ .memory = true });
}
