const std = @import("std");
const limine = @import("limine.zig");
const serial = @import("serial.zig");
const framebuffer = @import("framebuffer.zig");

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

// ENTRY(_start)
export fn _start() callconv(.c) noreturn {
    serial.init();
    serial.write("if you see this, it means revel didn't shit the bed\r\n");

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
