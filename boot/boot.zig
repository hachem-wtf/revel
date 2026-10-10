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
const fontdata = @import("fonts.zig");
const keyboard = @import("keyboard.zig");
const timer = @import("timer.zig");
const sched = @import("sched.zig");
const ata = @import("ata.zig");
const bridge = @import("bridge");

// we need a panic handler otherwise zig wont be happy,
// std usually formats a message through std.io.writer which
// emits sse instructions which i havent enabled. ours
// dumps the message to serial, then halts
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
// stderr io that doesnt exist on freestanding and wont even compile. this
// just points it to the custom one we wrote in bridge tthat uses the serial
// console and shit
pub const std_options_debug_io: std.Io = bridge.debug_io;

// note: check `linker.ld`
export var base_revision: limine.BaseRevision linksection(".limine_requests") = limine.BaseRevision.init(3);
export var requests_start: limine.RequestsStartMarker linksection(".limine_requests_start") = .{};
export var requests_end: limine.RequestsEndMarker linksection(".limine_requests_end") = .{};

// the loader fills these before we run so we read them through volatile pointers or
// the optimizer assumes theyre still the null we initialized them to
export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
export var memmap_request: limine.MemoryMapRequest linksection(".limine_requests") = .{};

// 4 mib stack
export var stack_size_request: limine.StackSizeRequest linksection(".limine_requests") = .{ .stack_size = 4 * 1024 * 1024 };

// wrappers matching bridge.kernelops (pmm/vmm return optionals, the revo facing
// primitives use 0 as the failure sentinel)
fn kPhysToVirt(phys: u64) u64 {
    return pmm.physToVirt(phys);
}

fn kAllocFrame() u64 {
    return pmm.alloc() orelse 0;
}

fn kAllocContig(count: u64) u64 {
    return pmm.allocContig(@intCast(count)) orelse 0;
}

fn kCreateAddrspace() u64 {
    return vmm.createAddressSpace() orelse 0;
}

fn kSerialNext() i64 {
    return if (serial.mirrorNext()) |byte| @intCast(byte) else -1;
}

// read only kernel state exposed to revo so it can present it (mem/uptime/ps and
// the memory map dump live in revo now)
var g_memmap: ?*const limine.MemoryMapResponse = null;

fn kMemmapCount() u64 {
    const mm = g_memmap orelse return 0;
    return mm.entry_count;
}

fn memmapEntry(i: u64) ?*const limine.MemoryMapEntry {
    const mm = g_memmap orelse return null;
    if (i >= mm.entry_count) return null;
    return mm.entries.?[i];
}

fn kMemmapBase(i: u64) u64 {
    return if (memmapEntry(i)) |entry| entry.base else 0;
}

fn kMemmapLen(i: u64) u64 {
    return if (memmapEntry(i)) |entry| entry.length else 0;
}

fn kMemmapKind(i: u64) u64 {
    return if (memmapEntry(i)) |entry| @backingInt(entry.type) else 0;
}

fn kMemFree() u64 {
    return pmm.freeBytes();
}

fn kMemTotal() u64 {
    return pmm.usableBytes();
}

fn kUptime() u64 {
    return timer.now();
}

fn kProcCount() u64 {
    return sched.procCount();
}

fn kDiskSectors() u64 {
    return ata.sectorCount();
}

fn kDiskRead(lba: u64, phys: u64) u64 {
    const buf: *[ata.SECTOR]u8 = @ptrFromInt(pmm.physToVirt(phys));
    return if (ata.read(@truncate(lba), buf)) 1 else 0;
}

fn kDiskWrite(lba: u64, phys: u64) u64 {
    const buf: *const [ata.SECTOR]u8 = @ptrFromInt(pmm.physToVirt(phys));
    return if (ata.write(@truncate(lba), buf)) 1 else 0;
}

// the embedded programs
const Prog = struct { name: []const u8, phys: u64, size: u64 };
var g_progs: [elf.programs.len]Prog = undefined;

fn loadPrograms() void {
    for (elf.programs, 0..) |program, i| {
        const pages = (program.bytes.len + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
        const phys = pmm.allocContig(pages) orelse @panic("no room for an embedded program");
        @memcpy(@as([*]u8, @ptrFromInt(pmm.physToVirt(phys)))[0..program.bytes.len], program.bytes);
        g_progs[i] = .{ .name = program.name, .phys = phys, .size = program.bytes.len };
    }
}

fn kProgCount() u64 {
    return g_progs.len;
}

fn kProgPhys(i: u64) u64 {
    return g_progs[i].phys;
}

fn kProgName(i: u64) []const u8 {
    return g_progs[i].name;
}

fn kProgSize(i: u64) u64 {
    return g_progs[i].size;
}

fn kTaskMax() u64 {
    return sched.taskMax();
}

// i dont actually like implementing fonts in any project
// it be revel or any opengl or vulkan or whatever the fuck
// fonts are always the ugh parts of a projects
// just so much boilerplate
const FontBlob = struct { name: []const u8, phys: u64, size: u64 };
var g_fonts: [fontdata.fonts.len]FontBlob = undefined;

fn loadFonts() void {
    for (fontdata.fonts, 0..) |font, i| {
        const pages = (font.bytes.len + pmm.PAGE_SIZE - 1) / pmm.PAGE_SIZE;
        const phys = pmm.allocContig(pages) orelse @panic("no room for an embedded font");
        @memcpy(@as([*]u8, @ptrFromInt(pmm.physToVirt(phys)))[0..font.bytes.len], font.bytes);
        g_fonts[i] = .{ .name = font.name, .phys = phys, .size = font.bytes.len };
    }
}

fn kFontCount() u64 {
    return g_fonts.len;
}

fn kFontPhys(i: u64) u64 {
    return g_fonts[i].phys;
}

fn kFontName(i: u64) []const u8 {
    return g_fonts[i].name;
}

fn kFontSize(i: u64) u64 {
    return g_fonts[i].size;
}

fn kTaskState(i: u64) u64 {
    return sched.taskState(i);
}

// limine doesnt fully enable SSE the only reason i need this
// is because Zig 0.17 bullshit
inline fn enableSse() void {
    asm volatile (
        \\ mov %%cr0, %%rax
        \\ and $0xfffb, %%ax
        \\ or  $0x2, %%ax
        \\ mov %%rax, %%cr0
        \\ mov %%cr4, %%rax
        \\ or  $0x600, %%rax
        \\ mov %%rax, %%cr4
        ::: .{ .rax = true, .memory = true });
}

// entry(_start)
export fn _start() callconv(.c) noreturn {
    enableSse();
    serial.init();
    serial.write("if you see this, it means revel didn't shit the bed\r\n");

    gdt.load();
    idt.init();
    user.installSyscall(); // int 0x80 gate at dpl 3
    // note: cpu interrupts stay off until the event loops sti
    //       which is after the vm has run that\
    serial.write("gdt + idt loaded\r\n");

    // hhdm + memory map -> physical frame allocator -> kernel heap
    const hhdm_req: *volatile limine.HhdmRequest = &hhdm_request;
    const memmap_req: *volatile limine.MemoryMapRequest = &memmap_request;
    const hhdm = hhdm_req.response orelse @panic("limine gave us no HHDM");
    const memmap = memmap_req.response orelse @panic("limine gave us no memory map");

    pmm.init(hhdm, memmap);
    g_memmap = memmap; // revo dumps it (dump_memmap) once the vm is up
    heap.init();

    pmmSelfTest();
    vmmSelfTest();
    ata.init();

    loadPrograms();
    loadFonts();
    // the event loop below is scheduler task 0 (the kernel), running in the
    // current cr3. user tasks spawned by `run` get time fucked against it
    sched.init(vmm.activePml4());

    const kops: bridge.KernelOps = .{
        .phys_to_virt = &kPhysToVirt,
        .alloc_frame = &kAllocFrame,
        .create_addrspace = &kCreateAddrspace,
        .spawn = &sched.spawn,
        .deliver_input = &sched.deliverInput,
        .proc_exited = &sched.takeProcExited,
        .serial_next = &kSerialNext,
        .memmap_count = &kMemmapCount,
        .memmap_base = &kMemmapBase,
        .memmap_len = &kMemmapLen,
        .memmap_kind = &kMemmapKind,
        .mem_free = &kMemFree,
        .mem_total = &kMemTotal,
        .uptime = &kUptime,
        .proc_count = &kProcCount,
        .prog_count = &kProgCount,
        .prog_phys = &kProgPhys,
        .prog_name = &kProgName,
        .prog_size = &kProgSize,
        .task_max = &kTaskMax,
        .task_state = &kTaskState,
        .disk_sectors = &kDiskSectors,
        .disk_read = &kDiskRead,
        .disk_write = &kDiskWrite,
        .alloc_contig = &kAllocContig,
        .font_count = &kFontCount,
        .font_phys = &kFontPhys,
        .font_name = &kFontName,
        .font_size = &kFontSize,
    };

    // hand the kernel heap + framebuffer + low level ops to revo and bring up the vm
    const fb: ?bridge.Fb = if (framebuffer.get()) |info| .{
        .ptr = info.address,
        .width = info.width,
        .height = info.height,
        .pitch = info.pitch,
    } else null;
    bridge.boot(heap.allocator(), serial.write, fb, kops);

    eventLoop();
}

// sanity check: two allocations should be distinct and non overlapping, and a
// freed frame should come straight back on the next alloc
fn pmmSelfTest() void {
    const first = pmm.alloc().?;
    const second = pmm.alloc().?;
    serial.write("pmm test: a=");
    serial.writeHex(first);
    serial.write(" b=");
    serial.writeHex(second);
    serial.write("\r\n");
    pmm.free(first);
    const refreed = pmm.alloc().?;
    serial.write("pmm test: freed a, realloc=");
    serial.writeHex(refreed);
    serial.write(if (refreed == first) " (reused, good)\r\n" else " (mismatch!)\r\n");
    pmm.free(second);
    pmm.free(refreed);
}

// map a fresh frame at an unused higher half address
// write a pattern
// read it back through the mapping
// create a separate address space
// switch into it (a bad cr3 triple faults)
// map + rw a lower half user page
// switch back
fn vmmSelfTest() void {
    const kernel_pattern: u64 = 0xDEAD_BEEF_CAFE_BABE;
    const user_pattern: u64 = 0x1234_5678_9ABC_DEF0;
    const pml4 = vmm.activePml4();
    const frame = pmm.alloc().?;
    const test_virt: u64 = 0xffff_c000_0000_0000;
    _ = vmm.map(pml4, test_virt, frame, vmm.WRITE);
    const cell: *volatile u64 = @ptrFromInt(test_virt);
    cell.* = kernel_pattern;
    serial.write("vmm test: map+rw ");
    serial.write(if (cell.* == kernel_pattern) "OK" else "FAIL");
    serial.write(", translate ");
    const back = vmm.translate(pml4, test_virt) orelse 0;
    serial.write(if (back == frame) "OK\r\n" else "FAIL\r\n");

    const as = vmm.createAddressSpace().?;
    const user_frame = pmm.alloc().?;
    const user_virt: u64 = 0x0000_0000_4000_0000; // 1 gib, lower half (user)
    _ = vmm.map(as, user_virt, user_frame, vmm.WRITE | vmm.USER);
    vmm.loadPml4(as);
    serial.write("vmm test: switched CR3 OK\r\n"); // reached => kernel still mapped
    const ucell: *volatile u64 = @ptrFromInt(user_virt);
    ucell.* = user_pattern;
    serial.write("vmm test: user page rw ");
    serial.write(if (ucell.* == user_pattern) "OK\r\n" else "FAIL\r\n");
    vmm.loadPml4(pml4); // back to the original address space
    serial.write("vmm test: switched back OK\r\n");
}

// 1- sleep until an interrupt
// 2- then drain the keyboard / tick
// 3- repeat
fn eventLoop() noreturn {
    var last_ticks: u64 = 0;
    while (true) {
        asm volatile ("cli");
        if (keyboard.pop()) |sc| {
            asm volatile ("sti");
            bridge.onKey(sc);
        } else if (timer.now() != last_ticks) {
            last_ticks = timer.now();
            asm volatile ("sti");
            bridge.onTick(last_ticks);
        } else {
            asm volatile ("sti; hlt");
        }
    }
}
