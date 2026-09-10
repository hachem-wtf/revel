// we have to make our own gdt even though limine gives us cause the
// spec says that the one they provide is only a temp one.
// in long mode, segment base/limits are ignrored so all we really encode
// is the access byte and the long mode bit.
// see: https://wiki.osdev.org/Global_Descriptor_Table

pub const KERNEL_CODE: u16 = 0x08;
pub const KERNEL_DATA: u16 = 0x10;

var gdt = [_]u64{
    0x0000000000000000, // null
    0x00209A0000000000, // 0x08 kernel code: present, ring 0, executable, L=1
    0x0000920000000000, // 0x10 kernel data: present, ring 0, writable
};

const Gdtr = packed struct {
    limit: u16,
    base: u64,
};

var gdtr: Gdtr = undefined;

// load the GDT, then reload CS (via a far return) and the data segments so the
// CPU actually uses our descriptors instead of Limine's shit one.
pub fn load() void {
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
        :
        : [gdtr] "r" (&gdtr),
        : .{ .rax = true, .memory = true });
}
