// GDT + TSS
// long mode ignores segment base/limit, so the segment descriptors
// only really carry the access byte + long-mode bit.
// we add ring-3 (user) code and data segments, and a TSS whose rsp0 is
// the kernel stack the CPU switches to when an interrupt fires while
// we're in user mode
//
// see: https://wiki.osdev.org/Global_Descriptor_Table
//      https://wiki.osdev.org/Task_State_Segment

pub const KERNEL_CODE: u16 = 0x08;
pub const KERNEL_DATA: u16 = 0x10;
pub const USER_CODE: u16 = 0x18; // OR with 3 (RPL) when loading into CS
pub const USER_DATA: u16 = 0x20; // OR with 3 (RPL) for SS
pub const TSS_SEL: u16 = 0x28;

// slots 5+6 (the 16-byte TSS descriptor) are filled at load() time
var gdt = [_]u64{
    0x0000000000000000, // 0x00 null
    0x00209A0000000000, // 0x08 kernel code: present, ring 0, exec, L=1
    0x0000920000000000, // 0x10 kernel data: present, ring 0, writable
    0x0020FA0000000000, // 0x18 user code:   present, ring 3, exec, L=1
    0x0000F20000000000, // 0x20 user data:   present, ring 3, writable
    0x0000000000000000, // 0x28 TSS low
    0x0000000000000000, //      TSS high
};

// x64 TSS
const Tss = packed struct {
    reserved0: u32 = 0,
    rsp0: u64 = 0,
    rsp1: u64 = 0,
    rsp2: u64 = 0,
    reserved1: u64 = 0,
    ist1: u64 = 0,
    ist2: u64 = 0,
    ist3: u64 = 0,
    ist4: u64 = 0,
    ist5: u64 = 0,
    ist6: u64 = 0,
    ist7: u64 = 0,
    reserved2: u64 = 0,
    reserved3: u16 = 0,
    iomap_base: u16 = 0,
};

var tss: Tss = .{};

// the stack the CPU lands on for a ring0 entry from ring3 (16 KiB)
var kernel_stack: [16 * 1024]u8 align(16) = undefined;

const Gdtr = packed struct {
    limit: u16,
    base: u64,
};

var gdtr: Gdtr = undefined;

// set the ring-0 stack used on the next interrupt-from-user (per process later)
pub fn setKernelStack(rsp0: u64) void {
    tss.rsp0 = rsp0;
}

// build the 16 byte TSS system descriptor from the TSS address + limit
fn tssDescriptor(base: u64, limit: u32) struct { low: u64, high: u64 } {
    var low: u64 = 0;
    low |= @as(u64, limit & 0xFFFF); // limit 0..15
    low |= @as(u64, base & 0xFFFF) << 16; // base 0..15
    low |= @as(u64, (base >> 16) & 0xFF) << 32; // base 16..23
    low |= @as(u64, 0x89) << 40; // access: present, type=9 (available 64-bit TSS)
    low |= @as(u64, (limit >> 16) & 0xF) << 48; // limit 16..19
    low |= @as(u64, (base >> 24) & 0xFF) << 56; // base 24..31
    return .{ .low = low, .high = (base >> 32) & 0xFFFFFFFF }; // base 32..63
}

// load the GDT, reload CS + data segments, then load the task register
pub fn load() void {
    tss.rsp0 = @intFromPtr(&kernel_stack) + kernel_stack.len; // stack grows down
    tss.iomap_base = @sizeOf(Tss); // no I/O bitmap
    const d = tssDescriptor(@intFromPtr(&tss), @sizeOf(Tss) - 1);
    gdt[5] = d.low;
    gdt[6] = d.high;

    gdtr = .{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    asm volatile (
        \\ lgdt (%[gdtr])
        \\ pushq $0x08
        \\ leaq 1f(%rip), %rax
        \\ pushq %rax
        \\ lretq
        \\ 1:
        \\ movw $0x10, %ax
        \\ movw %ax, %ds
        \\ movw %ax, %es
        \\ movw %ax, %fs
        \\ movw %ax, %gs
        \\ movw %ax, %ss
        \\ movw %[tss], %ax
        \\ ltr %ax
        :
        : [gdtr] "r" (&gdtr),
          [tss] "i" (@as(u16, TSS_SEL)),
        : .{ .rax = true, .memory = true });
}
