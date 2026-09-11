const std = @import("std");
const limine = @import("limine.zig");
const serial = @import("serial.zig");
const framebuffer = @import("framebuffer.zig");
const gdt = @import("gdt.zig");
const idt = @import("idt.zig");
const pmm = @import("pmm.zig");
const heap = @import("heap.zig");

// We need a panic handler otherwise zig won't be happy,
// std usually formats a message through std.Io.Writer which
// emits SSE instructions which I haven't enabled. Ours
// dumps the message to serial, then halts.
pub const panic = std.debug.FullPanic(struct {
    fn halt(msg: []const u8, _: ?usize) noreturn {
        serial.init();
        serial.write("\r\n!!! uhhhh engine kaput : ");
        serial.write(msg);
        serial.write("\r\n");
        while (true) asm volatile ("hlt");
    }
}.halt);

// Check `linker.ld`
export var base_revision: limine.BaseRevision linksection(".limine_requests") = limine.BaseRevision.init(3);
export var requests_start: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var requests_end: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

// the loader fills these before we run so we read them through volatile pointers or
// the optimizer assumes they're still the null we initialized them to
export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
export var memmap_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};

// ENTRY(_start)
export fn _start() callconv(.c) noreturn {
    serial.init();
    serial.write("if you see this, it means revel didn't shit the bed\r\n");

    gdt.load();
    idt.init();

    
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

    if (framebuffer.get()) |screen| {
        // XOR texture
        var y: usize = 0;
        while (y < screen.height) : (y += 1) {
            var x: usize = 0;
            while (x < screen.width) : (x += 1) {
                const v: u32 = @intCast((x ^ y) & 0xFF);
                framebuffer.putpixel(screen, x, y, (v << 16) | (v << 8) | v);
            }
        }
        serial.write("drew to the framebuffer\r\n");
    } else {
        serial.write("limine was a piece of shit.\r\n");
    }

    while (true) asm volatile ("hlt");
}
