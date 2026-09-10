const std = @import("std");
const limine = @import("limine.zig");

// We need a panic handler otherwise zig won't be happy,
// std usually formats a message through std.Io.Writer which
// emits SSE instructions which I haven't enabled. For now
// we just halt.
pub const panic = std.debug.FullPanic(struct {
    fn halt(_: []const u8, _: ?usize) noreturn {
        while (true) asm volatile ("hlt");
    }
}.halt);

// Check `linker.ld`
export var base_revision: limine.BaseRevision linksection(".limine_requests") = limine.BaseRevision.init(3);
export var requests_start: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var requests_end: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

// ENTRY(_start)
export fn _start() callconv(.c) noreturn {
    while (true) asm volatile ("hlt");
}
