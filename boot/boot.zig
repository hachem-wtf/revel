const std = @import("std");
const limine = @import("limine.zig");
const serial = @import("serial.zig");
const framebuffer = @import("framebuffer.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");
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

// ENTRY(_start)
export fn _start() callconv(.c) noreturn {
    serial.init();
    serial.write("if you see this, it means revel didn't shit the bed\r\n");

    gdt.load();
    idt.init();
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

    // hand the kernel heap + raw framebuffer to revo and bring up the VM
    const fb: ?bridge.Fb = if (framebuffer.get()) |s| .{
        .ptr = s.address,
        .width = s.width,
        .height = s.height,
        .pitch = s.pitch,
    } else null;
    bridge.boot(heap.allocator(), serial.write, fb);

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
