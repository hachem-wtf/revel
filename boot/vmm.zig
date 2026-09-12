// our own 4-level (x86_64) page tables, so we can build
// per-process address spaces and mark pages user-accessible
//
// physical frames come from the PMM, so we reach any frame through the HHDM
// (pmm.physToVirt) to read/write table entries. the privileged bits (reading
// CR3, invlpg) are the only asm here
//
// see: https://wiki.osdev.org/Paging

const pmm = @import("pmm.zig");

// page-table entry flag bits
pub const PRESENT: u64 = 1 << 0;
pub const WRITE: u64 = 1 << 1;
pub const USER: u64 = 1 << 2; // 1 = ring-3 accessible
pub const NX: u64 = 1 << 63; // WARNING: needs EFER.NXE, don't set unless enabled

// bits 12..51 of an entry hold the physical frame address
const ADDR_MASK: u64 = 0x000F_FFFF_FFFF_F000;

// physical base of the currently active PML4 (top of CR3)
pub fn activePml4() u64 {
    const cr3 = asm volatile ("mov %%cr3, %[out]"
        : [out] "=r" (-> u64),
    );
    return cr3 & ADDR_MASK;
}

// switch the active address space
pub fn loadPml4(pml4_phys: u64) void {
    asm volatile ("mov %[v], %%cr3"
        :
        : [v] "r" (pml4_phys),
        : .{ .memory = true });
}

pub fn invlpg(virt: u64) void {
    asm volatile ("invlpg (%[v])"
        :
        : [v] "r" (virt),
        : .{ .memory = true });
}

fn table(phys: u64) [*]volatile u64 {
    return @ptrFromInt(pmm.physToVirt(phys));
}

fn zeroFrame(phys: u64) void {
    const p: [*]u8 = @ptrFromInt(pmm.physToVirt(phys));
    @memset(p[0..pmm.PAGE_SIZE], 0);
}

// which 9 bit slice of the virtual address indexes level (3=PML4 .. 0=PT)
fn index(virt: u64, level: u6) usize {
    return @intCast((virt >> (12 + 9 * level)) & 0x1FF);
}

// return the physical base of the next-level table under entry i
// if missing, create one
fn nextTable(parent_phys: u64, i: usize, create: bool) ?u64 {
    const t = table(parent_phys);
    const entry = t[i];
    if (entry & PRESENT != 0) return entry & ADDR_MASK;
    if (!create) return null;
    const frame = pmm.alloc() orelse return null;
    zeroFrame(frame);
    t[i] = frame | PRESENT | WRITE | USER;
    return frame;
}

// map one 4 KiB page: virt -> phys with the given leaf flags (PRESENT is added
// returns false only if we ran out of frames for intermediate tables
pub fn map(pml4_phys: u64, virt: u64, phys: u64, flags: u64) bool {
    const pdpt = nextTable(pml4_phys, index(virt, 3), true) orelse return false;
    const pd = nextTable(pdpt, index(virt, 2), true) orelse return false;
    const pt = nextTable(pd, index(virt, 1), true) orelse return false;
    table(pt)[index(virt, 0)] = (phys & ADDR_MASK) | flags | PRESENT;
    invlpg(virt);
    return true;
}

// create a fresh address space
// a new PML4 that shares the kernel's higher half, so indices 256..511
// (kernel image, HHDM, stack, VM heap) but has an empty lower half for a
// process's own user memory. returns the new PML4 phys
//
// sharing is by copying the top-level entries, so every address space points at
// the SAME kernel page tables, the kernel stays mapped no matter which process
// is active, which is what lets us keep running after a CR3 switch
pub fn createAddressSpace() ?u64 {
    const pml4 = pmm.alloc() orelse return null;
    zeroFrame(pml4);
    const src = table(activePml4());
    const dst = table(pml4);
    var i: usize = 256;
    while (i < 512) : (i += 1) dst[i] = src[i];
    return pml4;
}

// walk the tables and return the physical address a virtual address maps to
// (page base | offset), or null if unmapped
// NOTE: mostly for debugging
pub fn translate(pml4_phys: u64, virt: u64) ?u64 {
    const pdpt = nextTable(pml4_phys, index(virt, 3), false) orelse return null;
    const pd = nextTable(pdpt, index(virt, 2), false) orelse return null;
    const pt = nextTable(pd, index(virt, 1), false) orelse return null;
    const entry = table(pt)[index(virt, 0)];
    if (entry & PRESENT == 0) return null;
    return (entry & ADDR_MASK) | (virt & 0xFFF);
}
