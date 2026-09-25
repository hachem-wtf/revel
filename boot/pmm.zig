// Physical memory manager: a bitmap of 4 KiB frames over Limine's memory map.
// this manages a bitmap of 4 KiB frames over limine's memory map.
// one bit per frame, 1 = used, 0 = free.
// this is just barely good enough to bootstrap a real heap later
// TODO: make this better lmao
//
// we never touch physical memory directly, everything goes through the HHDM
// offset (phys + offset = a virtual address limine already mapped for us)
//
// see: https://wiki.osdev.org/Physical_Memory_Allocation

const limine = @import("limine.zig");
const serial = @import("serial.zig");

pub const PAGE_SIZE: usize = 4096;

var hhdm_offset: u64 = 0;

// the bitmap itself lives inside a usable region (found at init time) and is
// reached through the HHDM, so it's just a normal slice we write through.
var bitmap: []u8 = &[_]u8{};

var total_frames: usize = 0; // frames the bitmap can index (up to highest usable end)
var usable_frames: usize = 0; // frames that started free
var free_frames: usize = 0; // frames currently free
var next_hint: usize = 0; // where to start the next alloc scan

pub fn physToVirt(phys: u64) u64 {
    return phys + hhdm_offset;
}

fn frameUsed(i: usize) bool {
    return (bitmap[i >> 3] & (@as(u8, 1) << @intCast(i & 7))) != 0;
}

fn markUsed(i: usize) void {
    bitmap[i >> 3] |= (@as(u8, 1) << @intCast(i & 7));
}

fn markFree(i: usize) void {
    bitmap[i >> 3] &= ~(@as(u8, 1) << @intCast(i & 7));
}

// walk a region's frames and apply f to each index. base is rounded up and
// end rounded down so we only ever touch whole frames fully inside the region.
fn forEachFrame(base: u64, length: u64, comptime f: fn (usize) void) void {
    const start = (base + PAGE_SIZE - 1) / PAGE_SIZE;
    const end = (base + length) / PAGE_SIZE;
    var i = start;
    while (i < end) : (i += 1) {
        if (i < total_frames) f(i);
    }
}

pub fn init(hhdm: *const limine.HhdmResponse, memmap: *const limine.MemoryMapResponse) void {
    hhdm_offset = hhdm.offset;
    const entries = memmap.entries.?[0..memmap.entry_count];

    // highest end of any usable region bounds the bitmap. we only ever
    //  alloc/free usable frames, so there's no point indexing past that
    var highest: u64 = 0;
    for (entries) |e| {
        if (e.type == .usable) {
            const top = e.base + e.length;
            if (top > highest) highest = top;
        }
    }
    total_frames = highest / PAGE_SIZE;
    const bitmap_bytes = (total_frames + 7) / 8;

    // park the bitmap in the first usable region big enough to hold it
    var storage_base: u64 = 0;
    for (entries) |e| {
        if (e.type == .usable and e.length >= bitmap_bytes) {
            storage_base = e.base;
            break;
        }
    }
    if (storage_base == 0 and bitmap_bytes > 0) @panic("pmm: no room for the frame bitmap");
    const ptr: [*]u8 = @ptrFromInt(physToVirt(storage_base));
    bitmap = ptr[0..bitmap_bytes];

    // start with everything used, then punch out the usable regions
    @memset(bitmap, 0xFF);
    for (entries) |e| {
        if (e.type == .usable) {
            forEachFrame(e.base, e.length, markFree);
            usable_frames += e.length / PAGE_SIZE;
        }
    }
    free_frames = usable_frames;

    // reclaim nothing that we're actually using, so the bitmap's own frames,
    // and frame 0.
    //
    // WARNING: never hand out a physical-null address
    //
    // unlike marking a region free, here we round the END UP so a partial
    // last frame the bitmap spills into still gets reserved
    {
        const start = storage_base / PAGE_SIZE;
        const end = (storage_base + bitmap_bytes + PAGE_SIZE - 1) / PAGE_SIZE;
        var i = start;
        while (i < end) : (i += 1) {
            if (i < total_frames) reserve(i);
        }
    }
    if (total_frames > 0) reserve(0);
}

// reserve = mark used
fn reserve(i: usize) void {
    if (!frameUsed(i)) {
        markUsed(i);
        free_frames -= 1;
    }
}

// hand out one physical frame, or null if we're out
// NOTE: returns a physical address
pub fn alloc() ?u64 {
    var i = next_hint;
    var scanned: usize = 0;
    while (scanned < total_frames) : (scanned += 1) {
        if (i >= total_frames) i = 0;
        if (!frameUsed(i)) {
            markUsed(i);
            free_frames -= 1;
            next_hint = i + 1;
            return @as(u64, i) * PAGE_SIZE;
        }
        i += 1;
    }
    return null;
}

// hand out n contiguous physical frames cause the heap needs one flat buffer, and a
// single usable region is contiguous in physical space, so this just finds a
// run of n free bits.
// NOTE: returns the base physical address of the run
pub fn allocContig(n: usize) ?u64 {
    if (n == 0) return null;
    var i: usize = 0;
    while (i + n <= total_frames) {
        var run: usize = 0;
        while (run < n and !frameUsed(i + run)) : (run += 1) {}
        if (run == n) {
            var j: usize = 0;
            while (j < n) : (j += 1) {
                markUsed(i + j);
                free_frames -= 1;
            }
            return @as(u64, i) * PAGE_SIZE;
        }
        // skip past the used frame that broke the run
        i += run + 1;
    }
    return null;
}

pub fn free(phys: u64) void {
    const i = phys / PAGE_SIZE;
    if (i < total_frames and frameUsed(i)) {
        markFree(i);
        free_frames += 1;
        if (i < next_hint) next_hint = i;
    }
}

pub fn freeBytes() u64 {
    return @as(u64, free_frames) * PAGE_SIZE;
}

pub fn usableBytes() u64 {
    return @as(u64, usable_frames) * PAGE_SIZE;
}

// dump the map + totals to serial so we can eyeball what limine gave us.
pub fn dump(memmap: *const limine.MemoryMapResponse) void {
    const entries = memmap.entries.?[0..memmap.entry_count];
    serial.write("memory map:\r\n");
    for (entries) |e| {
        serial.write("  ");
        serial.writeHex(e.base);
        serial.write(" len=");
        serial.writeHex(e.length);
        serial.write(" type=");
        serial.write(typeName(e.type));
        serial.write("\r\n");
    }
    serial.write("usable: ");
    serial.writeDec(usableBytes() / (1024 * 1024));
    serial.write(" MiB, free: ");
    serial.writeDec(freeBytes() / (1024 * 1024));
    serial.write(" MiB\r\n");
}

fn typeName(t: limine.MemoryType) []const u8 {
    return switch (t) {
        .usable => "usable",
        .reserved => "reserved",
        .acpi_reclaimable => "acpi-reclaimable",
        .acpi_nvs => "acpi-nvs",
        .bad => "bad",
        .bootloader_reclaimable => "bootloader-reclaimable",
        .kernel_and_modules => "kernel+modules",
        .framebuffer => "framebuffer",
        _ => "unknown",
    };
}
