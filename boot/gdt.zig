// gdt + tss
// long mode ignores segment base/limit, so the segment descriptors
// only really carry the access byte + long mode bit
// we add ring 3 (user) code and data segments, and a tss whose rsp0 is
// the kernel stack the cpu switches to when an interrupt fires while
// were in user mode
//
// see: https://wiki.osdev.org/Global_Descriptor_Table
//      https://wiki.osdev.org/Task_State_Segment

pub const KERNEL_CODE: u16 = 0x08;
pub const KERNEL_DATA: u16 = 0x10;
pub const USER_CODE: u16 = 0x18; // or with 3 (rpl) when loading into cs
pub const USER_DATA: u16 = 0x20; // or with 3 (rpl) for ss
pub const TSS_SEL: u16 = 0x28;

// slots 5+6 (the 16 byte tss descriptor) are filled at load() time
var gdt = [_]u64{
    0x0000000000000000, // 0x00 null
    0x00209A0000000000, // 0x08 kernel code: present, ring 0, exec, l=1
    0x0000920000000000, // 0x10 kernel data: present, ring 0, writable
    0x0020FA0000000000, // 0x18 user code:   present, ring 3, exec, l=1
    0x0000F20000000000, // 0x20 user data:   present, ring 3, writable
    0x0000000000000000, // 0x28 tss low
    0x0000000000000000, //      tss high
};

// x64 tss
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

// the stack the cpu lands on for a ring0 entry from ring3 (16 kib) so the scheduler
// overrides rsp0 per task, this is the boot default. the plain irq handlers run
// here and are tiny so 16 kib is fine ¯\_(ツ)_/¯
var kernel_stack: [16 * 1024]u8 align(16) = undefined;

var trap_stack: [2 * 1024 * 1024]u8 align(16) = undefined;
// #df/#pf use ist2 so a stack overflow lands on a known good stack and produces a
// loud exception dump instead of a silent triple fault
var fault_stack: [16 * 1024]u8 align(16) = undefined;

pub fn ist1Top() u64 {
    return @intFromPtr(&trap_stack) + trap_stack.len;
}
pub fn ist2Top() u64 {
    return @intFromPtr(&fault_stack) + fault_stack.len;
}

const Gdtr = packed struct {
    limit: u16,
    base: u64,
};

var gdtr: Gdtr = undefined;

// set the ring 0 stack used on the next interrupt from user (per process later)
pub fn setKernelStack(rsp0: u64) void {
    tss.rsp0 = rsp0;
}

// build the 16 byte tss system descriptor from the tss address + limit
fn tssDescriptor(base: u64, limit: u32) struct { low: u64, high: u64 } {
    var low: u64 = 0;
    low |= @as(u64, limit & 0xFFFF); // limit 0..15
    low |= @as(u64, base & 0xFFFF) << 16; // base 0..15
    low |= @as(u64, (base >> 16) & 0xFF) << 32; // base 16..23
    low |= @as(u64, 0x89) << 40; // access: present, type=9 (available 64 bit tss)
    low |= @as(u64, (limit >> 16) & 0xF) << 48; // limit 16..19
    low |= @as(u64, (base >> 24) & 0xFF) << 56; // base 24..31
    return .{ .low = low, .high = (base >> 32) & 0xFFFFFFFF }; // base 32..63
}

// load the gdt, reload cs + data segments, then load the task register
pub fn load() void {
    tss.rsp0 = @intFromPtr(&kernel_stack) + kernel_stack.len; // stack grows down
    tss.ist1 = ist1Top(); // big stack for int 0x80 (vm calls)
    tss.ist2 = ist2Top(); // fault stack for #df/#pf
    tss.iomap_base = @sizeOf(Tss); // no io bitmap
    const descriptor = tssDescriptor(@intFromPtr(&tss), @sizeOf(Tss) - 1);
    gdt[5] = descriptor.low; // tss descriptor spans slots 5 and 6
    gdt[6] = descriptor.high;

    gdtr = .{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    asm volatile (
        \\ lgdt (%[gdtr])
        \\ pushq %[kcode]
        \\ leaq 1f(%rip), %rax
        \\ pushq %rax
        \\ lretq
        \\ 1:
        \\ movw %[kdata], %ax
        \\ movw %ax, %ds
        \\ movw %ax, %es
        \\ movw %ax, %fs
        \\ movw %ax, %gs
        \\ movw %ax, %ss
        \\ movw %[tss], %ax
        \\ ltr %ax
        :
        : [gdtr] "r" (&gdtr),
          [kcode] "i" (@as(u16, KERNEL_CODE)),
          [kdata] "i" (@as(u16, KERNEL_DATA)),
          [tss] "i" (@as(u16, TSS_SEL)),
        : .{ .rax = true, .memory = true });
}
