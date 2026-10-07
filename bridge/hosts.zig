const std = @import("std");
const revo = @import("revo");
const serial = @import("serial.zig");
const convert = @import("convert.zig");

const HostResult = convert.HostResult;
const Data = convert.Data;
const argInt = convert.argInt;
const emit = serial.emit;

// gils shit
const Script = struct { name: []const u8, src: []const u8 };
const scripts = [_]Script{
    .{ .name = "ls", .src = @embedFile("k_gils_ls") },
    .{ .name = "tree", .src = @embedFile("k_gils_tree") },
    .{ .name = "cat", .src = @embedFile("k_gils_cat") },
    .{ .name = "rm", .src = @embedFile("k_gils_rm") },
    .{ .name = "mkdir", .src = @embedFile("k_gils_mkdir") },
    .{ .name = "touch", .src = @embedFile("k_gils_touch") },
    .{ .name = "cp", .src = @embedFile("k_gils_cp") },
    .{ .name = "mv", .src = @embedFile("k_gils_mv") },
    .{ .name = "wc", .src = @embedFile("k_gils_wc") },
    .{ .name = "head", .src = @embedFile("k_gils_head") },
    .{ .name = "tail", .src = @embedFile("k_gils_tail") },
};

// the actual framebuffer, the data layout feels pretty self explanatory
pub const Fb = struct {
    ptr: [*]u8,
    width: usize,
    height: usize,
    pitch: usize,
};
var g_fb: ?Fb = null;

pub fn setFb(fb: ?Fb) void {
    g_fb = fb;
}

pub const KernelOps = struct {
    phys_to_virt: *const fn (u64) u64,
    alloc_frame: *const fn () u64, // 0 on failure
    create_addrspace: *const fn () u64, // pml4 phys, 0 on failure (raw 64 bit entry copy incl. possible nx bit -> not f64 representable)
    spawn: *const fn (u64, u64, u64, u64, u64) void, // pml4, entry, ustack, arg_ptr, arg_len -> queue a ring 3 task
    deliver_input: *const fn (u8) bool, // hand a byte to a read()-blocked task, false if none
    proc_exited: *const fn () bool, // true once after a process exits (consumed)
    serial_next: *const fn () i64, // next mirrored serial byte, or -1 if empty

    // read only state for revo to present (mem/uptime/ps/dump_memmap):
    memmap_count: *const fn () u64,
    memmap_base: *const fn (u64) u64,
    memmap_len: *const fn (u64) u64,
    memmap_kind: *const fn (u64) u64,
    mem_free: *const fn () u64,
    mem_total: *const fn () u64,

    uptime: *const fn () u64,
    proc_count: *const fn () u64,
    prog_count: *const fn () u64,
    prog_phys: *const fn (u64) u64,
    prog_name: *const fn (u64) []const u8,
    prog_size: *const fn (u64) u64,
    task_max: *const fn () u64,
    task_state: *const fn (u64) u64,

    disk_sectors: *const fn () u64,
    disk_read: *const fn (u64, u64) u64, // lba, phys buf -> 1 ok / 0 fail
    disk_write: *const fn (u64, u64) u64, // lba, phys buf -> 1 ok / 0 fail
    alloc_contig: *const fn (u64) u64, // n contiguous pages -> phys base, 0 on fail

    font_count: *const fn () u64,
    font_phys: *const fn (u64) u64,
    font_name: *const fn (u64) []const u8,
    font_size: *const fn (u64) u64,
};
var g_kops: ?KernelOps = null;

pub fn setKops(ops: ?KernelOps) void {
    g_kops = ops;
}

fn kops() KernelOps {
    return g_kops.?;
}

// pass shit to revo
fn hostOutb(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const port = argInt(u16, args, 0) orelse return HostResult.other("outb: port out of range");
    const val = argInt(u8, args, 1) orelse return HostResult.other("outb: value out of range");
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (val),
          [p] "N{dx}" (port),
    );
    return HostResult.data(Data.new.nil());
}

// pass shit to revo
fn hostInb(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const port = argInt(u16, args, 0) orelse return HostResult.other("inb: port out of range");
    const val = asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "N{dx}" (port),
    );
    return HostResult.data(Data.new.num(val));
}

// pass shit to revo
fn hostPuts(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const string_id = args[0].asString() orelse return HostResult.other("puts: not a string");
    emit(vm.stringValue(string_id));
    return HostResult.data(Data.new.nil());
}

// pass shit to revo
fn hostFbWidth(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(if (g_fb) |fb| fb.width else 0));
}

// pass shit to revo
fn hostFbHeight(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(if (g_fb) |fb| fb.height else 0));
}

// color is 0xrrggbb in the usual limine 32 bpp layout
// pass shit to revo
fn hostFillRect(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const fb = g_fb orelse return HostResult.data(Data.new.nil()); // no screen, no op
    const x = argInt(usize, args, 0) orelse return HostResult.other("fill_rect: bad x");
    const y = argInt(usize, args, 1) orelse return HostResult.other("fill_rect: bad y");
    const w = argInt(usize, args, 2) orelse return HostResult.other("fill_rect: bad w");
    const h = argInt(usize, args, 3) orelse return HostResult.other("fill_rect: bad h");
    const color = argInt(u32, args, 4) orelse return HostResult.other("fill_rect: bad color");

    var yy = y;
    const y_end = @min(y + h, fb.height);
    const x_end = @min(x + w, fb.width);
    while (yy < y_end) : (yy += 1) {
        const row = fb.ptr + yy * fb.pitch;
        var xx = x;
        while (xx < x_end) : (xx += 1) {
            const px: *align(1) u32 = @ptrCast(row + xx * 4);
            px.* = color;
        }
    }
    return HostResult.data(Data.new.nil());
}

// pass shit to revo
fn hostFbScroll(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const fb = g_fb orelse return HostResult.data(Data.new.nil());
    const dy = argInt(usize, args, 0) orelse return HostResult.other("fb_scroll: bad dy");
    const color = argInt(u32, args, 1) orelse return HostResult.other("fb_scroll: bad color");
    if (dy == 0 or dy >= fb.height) return HostResult.data(Data.new.nil());
    const move_bytes = dy * fb.pitch;
    const total = fb.height * fb.pitch;
    std.mem.copyForwards(u8, fb.ptr[0 .. total - move_bytes], fb.ptr[move_bytes..total]);
    var y: usize = fb.height - dy;
    while (y < fb.height) : (y += 1) {
        const line = fb.ptr + y * fb.pitch;
        var x: usize = 0;
        while (x < fb.width) : (x += 1) {
            const px: *align(1) u32 = @ptrCast(line + x * 4);
            px.* = color;
        }
    }
    return HostResult.data(Data.new.nil());
}

// pass shit to revo
fn hostMemRead(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const phys = argInt(u64, args, 0) orelse return HostResult.other("mem_read: bad addr");
    const size = argInt(u64, args, 1) orelse return HostResult.other("mem_read: bad size");
    const virt = kops().phys_to_virt(phys);
    const val: u64 = switch (size) {
        1 => @as(*const u8, @ptrFromInt(virt)).*,
        2 => @as(*align(1) const u16, @ptrFromInt(virt)).*,
        4 => @as(*align(1) const u32, @ptrFromInt(virt)).*,
        8 => @as(*align(1) const u64, @ptrFromInt(virt)).*,
        else => return HostResult.other("mem_read: size must be 1/2/4/8"),
    };
    return HostResult.data(Data.new.num(val));
}

// pass shit to revo
fn hostMemCopy(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const dst = kops().phys_to_virt(argInt(u64, args, 0) orelse return HostResult.other("mem_copy: bad dst"));
    const src = kops().phys_to_virt(argInt(u64, args, 1) orelse return HostResult.other("mem_copy: bad src"));
    const len = argInt(usize, args, 2) orelse return HostResult.other("mem_copy: bad len");
    @memcpy(@as([*]u8, @ptrFromInt(dst))[0..len], @as([*]const u8, @ptrFromInt(src))[0..len]);
    return HostResult.data(Data.new.nil());
}

// pass shit to revo
fn hostMemZero(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const dst = kops().phys_to_virt(argInt(u64, args, 0) orelse return HostResult.other("mem_zero: bad addr"));
    const len = argInt(usize, args, 1) orelse return HostResult.other("mem_zero: bad len");
    @memset(@as([*]u8, @ptrFromInt(dst))[0..len], 0);
    return HostResult.data(Data.new.nil());
}

// pass shit to revo
fn hostMemWrite(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const phys = argInt(u64, args, 0) orelse return HostResult.other("mem_write: bad addr");
    const val = argInt(u64, args, 1) orelse return HostResult.other("mem_write: bad val");
    const size = argInt(u64, args, 2) orelse return HostResult.other("mem_write: bad size");
    const virt = kops().phys_to_virt(phys);
    switch (size) {
        1 => @as(*u8, @ptrFromInt(virt)).* = @truncate(val),
        2 => @as(*align(1) u16, @ptrFromInt(virt)).* = @truncate(val),
        4 => @as(*align(1) u32, @ptrFromInt(virt)).* = @truncate(val),
        8 => @as(*align(1) u64, @ptrFromInt(virt)).* = val,
        else => return HostResult.other("mem_write: size must be 1/2/4/8"),
    }
    return HostResult.data(Data.new.nil());
}

// pass shit to revo
fn hostInvlpg(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const virt = argInt(u64, args, 0) orelse return HostResult.other("invlpg: bad addr");
    asm volatile ("invlpg (%[v])"
        :
        : [v] "r" (virt),
        : .{ .memory = true });
    return HostResult.data(Data.new.nil());
}

// pass shit to revo
fn hostFrameAlloc(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().alloc_frame()));
}

// pass shit to revo
fn hostAsCreate(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().create_addrspace()));
}

// pass shit to revo
fn hostProcRun(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const as = argInt(u64, args, 0) orelse return HostResult.other("proc_run: bad as");
    const entry = argInt(u64, args, 1) orelse return HostResult.other("proc_run: bad entry");
    const ustack = argInt(u64, args, 2) orelse return HostResult.other("proc_run: bad ustack");
    const arg = argInt(u64, args, 3) orelse return HostResult.other("proc_run: bad arg");
    const arglen = argInt(u64, args, 4) orelse return HostResult.other("proc_run: bad arglen");
    kops().spawn(as, entry, ustack, arg, arglen);
    return HostResult.data(Data.new.nil());
}

// pass shit to revo
fn hostStdinDeliver(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ch = argInt(u8, args, 0) orelse return HostResult.other("stdin_deliver: bad char");
    return HostResult.data(Data.new.num(if (kops().deliver_input(ch)) @as(f64, 1) else 0));
}

// pass shit to revo
fn hostProcExited(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(if (kops().proc_exited()) @as(f64, 1) else 0));
}

// pass shit to revo
fn hostSerialNext(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().serial_next()));
}

// pass shit to revo
fn hostProgCount(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().prog_count()));
}

// pass shit to revo
fn hostProgPhys(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const i = argInt(u64, args, 0) orelse return HostResult.other("prog_phys: bad index");
    return HostResult.data(Data.new.num(kops().prog_phys(i)));
}

// pass shit to revo
fn hostProgName(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const i = argInt(u64, args, 0) orelse return HostResult.other("prog_name: bad index");
    return HostResult.data(try vm.ownValueString(kops().prog_name(i)));
}

// pass shit to revo
fn hostProgSize(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const i = argInt(u64, args, 0) orelse return HostResult.other("prog_size: bad index");
    return HostResult.data(Data.new.num(kops().prog_size(i)));
}

// pass shit to revo
fn hostFontCount(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().font_count()));
}

// pass shit to revo
fn hostFontPhys(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const i = argInt(u64, args, 0) orelse return HostResult.other("font_phys: bad index");
    return HostResult.data(Data.new.num(kops().font_phys(i)));
}

// pass shit to revo
fn hostFontName(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const i = argInt(u64, args, 0) orelse return HostResult.other("font_name: bad index");
    return HostResult.data(try vm.ownValueString(kops().font_name(i)));
}

// pass shit to revo
fn hostFontSize(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const i = argInt(u64, args, 0) orelse return HostResult.other("font_size: bad index");
    return HostResult.data(Data.new.num(kops().font_size(i)));
}

// pass shit to revo
fn hostTaskMax(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().task_max()));
}

// pass shit to revo
fn hostTaskState(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const i = argInt(u64, args, 0) orelse return HostResult.other("task_state: bad index");
    return HostResult.data(Data.new.num(kops().task_state(i)));
}

// pass shit to revo
fn hostMemmapCount(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().memmap_count()));
}

// pass shit to revo
fn hostMemmapBase(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const index = argInt(u64, args, 0) orelse return HostResult.other("memmap_base: bad index");
    return HostResult.data(Data.new.num(kops().memmap_base(index)));
}

// pass shit to revo
fn hostMemmapLen(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const index = argInt(u64, args, 0) orelse return HostResult.other("memmap_len: bad index");
    return HostResult.data(Data.new.num(kops().memmap_len(index)));
}

// pass shit to revo
fn hostMemmapKind(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const index = argInt(u64, args, 0) orelse return HostResult.other("memmap_kind: bad index");
    return HostResult.data(Data.new.num(kops().memmap_kind(index)));
}

// pass shit to revo
fn hostMemFree(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().mem_free()));
}

// pass shit to revo
fn hostMemTotal(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().mem_total()));
}

// pass shit to revo
fn hostUptime(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().uptime()));
}

// pass shit to revo
fn hostProcCount(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().proc_count()));
}

// pass shit to revo
fn hostDiskSectors(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(kops().disk_sectors()));
}

// pass shit to revo
fn hostDiskRead(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const lba = argInt(u64, args, 0) orelse return HostResult.other("disk_read: bad lba");
    const phys = argInt(u64, args, 1) orelse return HostResult.other("disk_read: bad phys");
    return HostResult.data(Data.new.num(kops().disk_read(lba, phys)));
}

// pass shit to revo
fn hostDiskWrite(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const lba = argInt(u64, args, 0) orelse return HostResult.other("disk_write: bad lba");
    const phys = argInt(u64, args, 1) orelse return HostResult.other("disk_write: bad phys");
    return HostResult.data(Data.new.num(kops().disk_write(lba, phys)));
}

// pass shit to revo
fn hostAllocContig(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const n = argInt(u64, args, 0) orelse return HostResult.other("alloc_contig: bad count");
    return HostResult.data(Data.new.num(kops().alloc_contig(n)));
}

// pass shit to revo
fn hostBlitStr(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const phys = argInt(u64, args, 0) orelse return HostResult.other("blit_str: bad addr");
    const sid = args[1].asString() orelse return HostResult.other("blit_str: not a string");
    const bytes = vm.stringValue(sid);
    const dst: [*]u8 = @ptrFromInt(kops().phys_to_virt(phys));
    @memcpy(dst[0..bytes.len], bytes);
    return HostResult.data(Data.new.num(bytes.len));
}

// pass shit to revo
fn hostPhysToStr(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const phys = argInt(u64, args, 0) orelse return HostResult.other("phys_to_str: bad addr");
    const len = argInt(usize, args, 1) orelse return HostResult.other("phys_to_str: bad len");
    const src: [*]const u8 = @ptrFromInt(kops().phys_to_virt(phys));
    return HostResult.data(try vm.ownValueString(src[0..len]));
}

// pass shit to revo
fn hostScriptCount(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(scripts.len));
}

// pass shit to revo
fn hostScriptName(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const i = argInt(usize, args, 0) orelse return HostResult.other("script_name: bad index");
    if (i >= scripts.len) return HostResult.other("script_name: out of range");
    return HostResult.data(try vm.ownValueString(scripts[i].name));
}

// pass shit to revo
fn hostScriptSrc(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const i = argInt(usize, args, 0) orelse return HostResult.other("script_src: bad index");
    if (i >= scripts.len) return HostResult.other("script_src: out of range");
    return HostResult.data(try vm.ownValueString(scripts[i].src));
}

// pass shit to revo
fn hostEvalScript(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const sid = args[0].asString() orelse return HostResult.other("eval_script: not a string");
    const src = vm.stringValue(sid);
    const res = revo.run.runModule(vm, "<script>", src, false) catch |e| {
        return HostResult.data(try vm.ownValueString(@errorName(e)));
    };
    return switch (res) {
        .ok => HostResult.data(Data.new.nil()),
        .err => HostResult.data(try vm.ownValueString("script runtime error")),
    };
}

// pass shit to revo
pub fn passShitToRevo(vm: *revo.VM) !void {
    const define = revo.baselib.host.define;
    const T = revo.baselib.host.ParamType;
    try vm.registerGlobal("outb", try vm.installHost("outb", define(&[_]T{ .number, .number }, hostOutb)));
    try vm.registerGlobal("inb", try vm.installHost("inb", define(&[_]T{.number}, hostInb)));
    try vm.registerGlobal("serial_puts", try vm.installHost("serial_puts", define(&[_]T{.string}, hostPuts)));
    try vm.registerGlobal("fb_width", try vm.installHost("fb_width", define(&[_]T{}, hostFbWidth)));
    try vm.registerGlobal("fb_height", try vm.installHost("fb_height", define(&[_]T{}, hostFbHeight)));
    try vm.registerGlobal("fill_rect", try vm.installHost("fill_rect", define(&[_]T{ .number, .number, .number, .number, .number }, hostFillRect)));
    try vm.registerGlobal("fb_scroll", try vm.installHost("fb_scroll", define(&[_]T{ .number, .number }, hostFbScroll)));

    try vm.registerGlobal("mem_read", try vm.installHost("mem_read", define(&[_]T{ .number, .number }, hostMemRead)));
    try vm.registerGlobal("mem_copy", try vm.installHost("mem_copy", define(&[_]T{ .number, .number, .number }, hostMemCopy)));
    try vm.registerGlobal("mem_zero", try vm.installHost("mem_zero", define(&[_]T{ .number, .number }, hostMemZero)));
    try vm.registerGlobal("mem_write", try vm.installHost("mem_write", define(&[_]T{ .number, .number, .number }, hostMemWrite)));
    try vm.registerGlobal("invlpg", try vm.installHost("invlpg", define(&[_]T{.number}, hostInvlpg)));
    try vm.registerGlobal("frame_alloc", try vm.installHost("frame_alloc", define(&[_]T{}, hostFrameAlloc)));
    try vm.registerGlobal("as_create", try vm.installHost("as_create", define(&[_]T{}, hostAsCreate)));
    try vm.registerGlobal("proc_run", try vm.installHost("proc_run", define(&[_]T{ .number, .number, .number, .number, .number }, hostProcRun)));
    try vm.registerGlobal("stdin_deliver", try vm.installHost("stdin_deliver", define(&[_]T{.number}, hostStdinDeliver)));
    try vm.registerGlobal("proc_exited", try vm.installHost("proc_exited", define(&[_]T{}, hostProcExited)));
    try vm.registerGlobal("serial_next", try vm.installHost("serial_next", define(&[_]T{}, hostSerialNext)));
    try vm.registerGlobal("prog_count", try vm.installHost("prog_count", define(&[_]T{}, hostProgCount)));
    try vm.registerGlobal("prog_phys", try vm.installHost("prog_phys", define(&[_]T{.number}, hostProgPhys)));
    try vm.registerGlobal("prog_name", try vm.installHost("prog_name", define(&[_]T{.number}, hostProgName)));
    try vm.registerGlobal("prog_size", try vm.installHost("prog_size", define(&[_]T{.number}, hostProgSize)));
    try vm.registerGlobal("font_count", try vm.installHost("font_count", define(&[_]T{}, hostFontCount)));
    try vm.registerGlobal("font_phys", try vm.installHost("font_phys", define(&[_]T{.number}, hostFontPhys)));
    try vm.registerGlobal("font_name", try vm.installHost("font_name", define(&[_]T{.number}, hostFontName)));
    try vm.registerGlobal("font_size", try vm.installHost("font_size", define(&[_]T{.number}, hostFontSize)));
    try vm.registerGlobal("task_max", try vm.installHost("task_max", define(&[_]T{}, hostTaskMax)));
    try vm.registerGlobal("task_state", try vm.installHost("task_state", define(&[_]T{.number}, hostTaskState)));
    try vm.registerGlobal("memmap_count", try vm.installHost("memmap_count", define(&[_]T{}, hostMemmapCount)));
    try vm.registerGlobal("memmap_base", try vm.installHost("memmap_base", define(&[_]T{.number}, hostMemmapBase)));
    try vm.registerGlobal("memmap_len", try vm.installHost("memmap_len", define(&[_]T{.number}, hostMemmapLen)));
    try vm.registerGlobal("memmap_kind", try vm.installHost("memmap_kind", define(&[_]T{.number}, hostMemmapKind)));
    try vm.registerGlobal("mem_free", try vm.installHost("mem_free", define(&[_]T{}, hostMemFree)));
    try vm.registerGlobal("mem_total", try vm.installHost("mem_total", define(&[_]T{}, hostMemTotal)));
    try vm.registerGlobal("uptime", try vm.installHost("uptime", define(&[_]T{}, hostUptime)));
    try vm.registerGlobal("proc_count", try vm.installHost("proc_count", define(&[_]T{}, hostProcCount)));

    try vm.registerGlobal("disk_sectors", try vm.installHost("disk_sectors", define(&[_]T{}, hostDiskSectors)));
    try vm.registerGlobal("disk_read", try vm.installHost("disk_read", define(&[_]T{ .number, .number }, hostDiskRead)));
    try vm.registerGlobal("disk_write", try vm.installHost("disk_write", define(&[_]T{ .number, .number }, hostDiskWrite)));

    try vm.registerGlobal("eval_script", try vm.installHost("eval_script", define(&[_]T{.string}, hostEvalScript)));
    try vm.registerGlobal("script_count", try vm.installHost("script_count", define(&[_]T{}, hostScriptCount)));
    try vm.registerGlobal("script_name", try vm.installHost("script_name", define(&[_]T{.number}, hostScriptName)));
    try vm.registerGlobal("script_src", try vm.installHost("script_src", define(&[_]T{.number}, hostScriptSrc)));
    try vm.registerGlobal("alloc_contig", try vm.installHost("alloc_contig", define(&[_]T{.number}, hostAllocContig)));
    try vm.registerGlobal("blit_str", try vm.installHost("blit_str", define(&[_]T{ .number, .string }, hostBlitStr)));
    try vm.registerGlobal("phys_to_str", try vm.installHost("phys_to_str", define(&[_]T{ .number, .number }, hostPhysToStr)));
}
