// this just grabs a contiguous chunk of frams from the pmm and then
// hands out a bump allocator, this just gives std.mem.allocator which
// well pass to the revo vm later. fixedbufferallocator never reclaims
// freed space unless you free in reverse order which is ehhhhh, fine ig
// for bootstrapping
//
// todo: swap fixed buffer allocator for a free list allocator

const std = @import("std");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

// 32 mib
// note: bump if the vm needs more
const HEAP_PAGES: usize = 8192;

var fba: std.heap.FixedBufferAllocator = undefined;

pub fn init() void {
    const phys = pmm.allocContig(HEAP_PAGES) orelse @panic("heap: no contiguous frames for the heap");
    const virt = pmm.physToVirt(phys);
    const buf: [*]u8 = @ptrFromInt(virt);
    fba = std.heap.FixedBufferAllocator.init(buf[0 .. HEAP_PAGES * pmm.PAGE_SIZE]);

    serial.write("heap: ");
    serial.writeDec((HEAP_PAGES * pmm.PAGE_SIZE) / (1024 * 1024));
    serial.write(" MiB at ");
    serial.writeHex(virt);
    serial.write("\r\n");
}

pub fn allocator() std.mem.Allocator {
    return fba.allocator();
}
