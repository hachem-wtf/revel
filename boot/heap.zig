// freelist allocator type shit

const std = @import("std");
const pmm = @import("pmm.zig");
const serial = @import("serial.zig");

const HEAP_PAGES: usize = 16384; // 64 mib
const HEADER: usize = 16; // keeps payloads 16 aligned
const ALIGN: usize = 16;
const MIN_BLOCK: usize = 32; // header + a usable scrap, dont split below this

var heap_start: usize = 0;
var heap_end: usize = 0;
// next fit rover optimization. essentially its resume scanning where hte last
// alloc landed instead of heap_start everytime. it was O(n) before
var rover: usize = 0;

inline fn word(b: usize) *usize {
    return @ptrFromInt(b);
}
inline fn blkSize(b: usize) usize {
    return word(b).* & ~@as(usize, 0xf);
}
inline fn blkUsed(b: usize) bool {
    return (word(b).* & 1) != 0;
}
inline fn setBlk(b: usize, size: usize, used: bool) void {
    word(b).* = size | @as(usize, if (used) 1 else 0);
}
inline fn alignUp(x: usize, a: usize) usize {
    return (x + a - 1) & ~(a - 1);
}

pub fn init() void {
    const phys = pmm.allocContig(HEAP_PAGES) orelse @panic("heap: no contiguous frames for the heap");
    heap_start = pmm.physToVirt(phys);
    const total = HEAP_PAGES * pmm.PAGE_SIZE;
    heap_end = heap_start + total;
    setBlk(heap_start, total, false); // start as one big free block

    serial.write("heap: ");
    serial.writeDec(total / (1024 * 1024));
    serial.write(" MiB free-list at ");
    serial.writeHex(heap_start);
    serial.write("\r\n");
}

fn allocImpl(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    // we only guarantee 16 byte payload alignment
    // anything else can like actually go fuck itself
    if (alignment.toByteUnits() > ALIGN) return null;
    const need = alignUp(HEADER + len, ALIGN);

    if (rover < heap_start or rover >= heap_end) rover = heap_start;

    // next fit bull shit
    var b = rover;
    var limit = heap_end;
    var pass: u8 = 0;
    while (pass < 2) : (pass += 1) {
        while (b < limit) {
            if (!blkUsed(b)) {
                // lazy coalesce
                var size = blkSize(b);
                while (b + size < heap_end and !blkUsed(b + size)) size += blkSize(b + size);
                setBlk(b, size, false);

                if (size >= need) {
                    if (size >= need + MIN_BLOCK) {
                        setBlk(b, need, true);
                        setBlk(b + need, size - need, false); // the leftover tail
                        rover = b + need;
                    } else {
                        setBlk(b, size, true);
                        rover = b + size;
                    }
                    if (rover >= heap_end) rover = heap_start;
                    return @ptrFromInt(b + HEADER);
                }
            }
            b += blkSize(b);
        }
        // wrap
        b = heap_start;
        limit = rover;
    }
    return null;
}

fn freeImpl(_: *anyopaque, buf: []u8, _: std.mem.Alignment, _: usize) void {
    const b = @intFromPtr(buf.ptr) - HEADER;
    setBlk(b, blkSize(b), false);
}

fn resizeImpl(_: *anyopaque, buf: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const b = @intFromPtr(buf.ptr) - HEADER;
    return new_len <= blkSize(b) - HEADER;
}

fn remapImpl(ctx: *anyopaque, buf: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    if (resizeImpl(ctx, buf, alignment, new_len, ra)) return buf.ptr;
    return null;
}

const vtable = std.mem.Allocator.VTable{
    .alloc = allocImpl,
    .resize = resizeImpl,
    .remap = remapImpl,
    .free = freeImpl,
};

pub fn allocator() std.mem.Allocator {
    return .{ .ptr = undefined, .vtable = &vtable };
}
