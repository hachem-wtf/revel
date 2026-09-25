const std = @import("std");
const limine = @import("limine.zig");
const serial = @import("serial.zig");
const framebuffer = @import("framebuffer.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");
const vmm = @import("vmm.zig");
const user = @import("user.zig");
const elf = @import("elf.zig");
const keyboard = @import("keyboard.zig");
const bridge = @import("bridge");

// We need a panic handler otherwise zig won't be happy,
// std usually formats a message through std.Io.Writer which
// emits SSE instructions which I haven't enabled. Ours
// dumps the message to serial, then halts.
pub const panic = std.debug.FullPanic(struct {
    fn halt(msg: []const u8, ret_addr: ?usize) noreturn {
        serial.init();
        serial.write("\r\n!!! uhhhh engine kaput : ");
        serial.write(msg);
        if (ret_addr) |ra| {
            serial.write("\r\n  at ");
            serial.writeHex(ra);
        }
        serial.write("\r\n");
        while (true) asm volatile ("hlt");
    }
}.halt);

// std.debug.print (revo hits it on a few error paths) defaults to a threaded
// stderr IO that doesn't exist on freestanding and won't even compile. This
// just points it to the custom one we wrote in bridge tthat uses the serial
// console and shit
pub const std_options_debug_io: std.Io = bridge.debug_io;

// Check `linker.ld`
export var base_revision: limine.BaseRevision linksection(".limine_requests") = limine.BaseRevision.init(3);
export var requests_start: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var requests_end: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

// the loader fills these before we run so we read them through volatile pointers or
// the optimizer assumes they're still the null we initialized them to
export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
export var memmap_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};

// 4 MiB stack
export var stack_size_request: limine.StackSizeRequest linksection(".limine_requests") = .{ .stack_size = 4 * 1024 * 1024 };

// wrappers matching bridge.KernelOps (pmm/vmm return optionals; the revo-facing
// primitives use 0 as the failure sentinel).
fn kPhysToVirt(p: u64) u64 {
    return pmm.physToVirt(p);
}
fn kAllocFrame() u64 {
    return pmm.alloc() orelse 0;
}
fn kCreateAddrspace() u64 {
    return vmm.createAddressSpace() orelse 0;
}
fn kSerialNext() i64 {
    return if (serial.mirrorNext()) |c| @intCast(c) else -1;
}

// ENTRY(_start)
export fn _start() callconv(.c) noreturn {
    serial.init();
    serial.write("if you see this, it means revel didn't shit the bed\r\n");

    gdt.load();
    idt.init();
    user.installSyscall(); // int 0x80 gate at DPL 3
    // NOTE: CPU interrupts stay off until the event loop's sti
    //       which is after the VM has run that\
    serial.write("gdt + idt loaded\r\n");

    // HHDM + memory map -> physical frame allocator -> kernel heap
    const hhdm_req: *volatile limine.HhdmRequest = &hhdm_request;
    const memmap_req: *volatile limine.MemoryMapRequest = &memmap_request;
    const hhdm = hhdm_req.response orelse @panic("limine gave us no HHDM");
    const memmap = memmap_req.response orelse @panic("limine gave us no memory map");

    pmm.init(hhdm, memmap);
    pmm.dump(memmap);
    heap.init();

    // NOTE: this is a sanity check
    // two allocations should be distinct and non-overlapping,
    // and a freed frame should come straight back on the next alloc.
    const a = pmm.alloc().?;
    const b = pmm.alloc().?;
    serial.write("pmm test: a=");
    serial.writeHex(a);
    serial.write(" b=");
    serial.writeHex(b);
    serial.write("\r\n");
    pmm.free(a);
    const c = pmm.alloc().?;
    serial.write("pmm test: freed a, realloc=");
    serial.writeHex(c);
    serial.write(if (c == a) " (reused, good)\r\n" else " (mismatch!)\r\n");
    pmm.free(b);
    pmm.free(c);

    // this is just a VMM smoke test
    // we map a fresh frame at an unused higher half address in the
    // active address space, write a pattern, read it back through the mapping
    {
        const pml4 = vmm.activePml4();
        const frame = pmm.alloc().?;
        const test_virt: u64 = 0xffff_c000_0000_0000;
        _ = vmm.map(pml4, test_virt, frame, vmm.WRITE);
        const cell: *volatile u64 = @ptrFromInt(test_virt);
        cell.* = 0xDEADBEEFCAFEBABE;
        serial.write("vmm test: map+rw ");
        serial.write(if (cell.* == 0xDEADBEEFCAFEBABE) "OK" else "FAIL");
        serial.write(", translate ");
        const back = vmm.translate(pml4, test_virt) orelse 0;
        serial.write(if (back == frame) "OK\r\n" else "FAIL\r\n");

        // create a separate address space, switch into it (the scary part -- a
        // bad CR3 triple-faults), map a lower-half user page, read/write it,
        // then switch back. if the kernel keeps running, address spaces work.
        const as = vmm.createAddressSpace().?;
        const user_frame = pmm.alloc().?;
        const user_virt: u64 = 0x0000_0000_4000_0000; // 1 GiB, lower half (user)
        _ = vmm.map(as, user_virt, user_frame, vmm.WRITE | vmm.USER);
        vmm.loadPml4(as);
        serial.write("vmm test: switched CR3 OK\r\n"); // reached => kernel still mapped
        const ucell: *volatile u64 = @ptrFromInt(user_virt);
        ucell.* = 0x1234_5678_9ABC_DEF0;
        serial.write("vmm test: user page rw ");
        serial.write(if (ucell.* == 0x123456789ABCDEF0) "OK\r\n" else "FAIL\r\n");
        vmm.loadPml4(pml4); // back to the original address space
        serial.write("vmm test: switched back OK\r\n");
    }

    const elf_pages = (elf.hello_elf.len + 4095) / 4096;
    const elf_phys = pmm.allocContig(elf_pages) orelse @panic("no room for the embedded ELF");
    @memcpy(@as([*]u8, @ptrFromInt(pmm.physToVirt(elf_phys)))[0..elf.hello_elf.len], elf.hello_elf);
    const kops: bridge.KernelOps = .{
        .phys_to_virt = &kPhysToVirt,
        .alloc_frame = &kAllocFrame,
        .create_addrspace = &kCreateAddrspace,
        .run_process = &user.runProcess,
        .serial_next = &kSerialNext,
        .elf_phys = elf_phys,
        .elf_size = elf.hello_elf.len,
    };

    // hand the kernel heap + framebuffer + low-level ops to revo and bring up the VM
    const fb: ?bridge.Fb = if (framebuffer.get()) |s| .{
        .ptr = s.address,
        .width = s.width,
        .height = s.height,
        .pitch = s.pitch,
    } else null;
    bridge.boot(heap.allocator(), serial.write, fb, kops);

    // - sleep until an interrupt
    // - drain the keyboard
    // - repeat.
    //
    // the cli/pop/sti-hlt bullshit closes the lost-wakeup race (a key
    // arriving between "queue empty" and hlt would otherwise sit until
    // the next keypress)
    while (true) {
        asm volatile ("cli");
        if (keyboard.pop()) |sc| {
            asm volatile ("sti");
            bridge.onKey(sc);
        } else {
            asm volatile ("sti; hlt");
        }
    }
}
