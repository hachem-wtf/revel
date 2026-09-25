// so the thing is right, revo isn't really that low level and we need to have a
// thin bridge to translate shit over. Its just to setup the VM, serial ports,
// heap shit like that.

const std = @import("std");
const revo = @import("revo");

// all the VM's output goes here, boot injects this at runtime so the
// bridge doesn't need to pull a serial port from its ass
pub const Sink = *const fn ([]const u8) void;
fn noopSink(_: []const u8) void {}
var sink: Sink = noopSink;

// fan a multi-slice write payload out to the sink.
// mirrors the shape of std.Io's file_write_streaming request so
// an optional header, then the data whose LAST slice is repeated
// splat times.
// idk why zig chose these names, they are funny af.
// NOTE: returns the total byte count written.
fn writeToSink(
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) std.Io.Operation.FileWriteStreaming.Result {
    if (header.len > 0) emit(header);
    for (data[0..data.len -| 1]) |slice| {
        if (slice.len > 0) emit(slice);
    }
    const last = data[data.len -| 1];
    var i: usize = 0;
    while (i < splat) : (i += 1) {
        if (last.len > 0) emit(last);
    }

    var total: usize = header.len;
    for (data[0..data.len -| 1]) |slice| total += slice.len;
    total += last.len * splat;
    return total;
}

// every file write (stdout, stderr, whatever) routes to the serial port but we
// don't have a filesystem or multiple sinks yet, so there's nowhere else to go
fn ioOperate(_: ?*anyopaque, operation: std.Io.Operation) std.Io.Cancelable!std.Io.Operation.Result {
    return switch (operation) {
        .file_write_streaming => |req| .{
            .file_write_streaming = writeToSink(req.header, req.data, req.splat),
        },
        .file_read_streaming => .{ .file_read_streaming = error.InputOutput },
        .device_io_control => .{ .device_io_control = -1 },
        .net_receive => .{ .net_receive = .{ error.NetworkDown, 0 } },
    };
}

// no timer wired up yet, so time stands still,
// call me the time bender the way i fuck shit up
// TODO: fine until we have the PIT/TSC
fn ioNow(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
    return .{ .nanoseconds = 0 };
}

fn ioClockResolution(_: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    return .{ .nanoseconds = 1_000_000 };
}

// the scheduler parks fibers itself, it never needs us to actually block
fn ioSleep(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {}

fn ioCrashHandler(_: ?*anyopaque) void {}

// eval captures its own errors into a buffer, so this is never reached lol
//  return Canceled rather than recursing into a stderr lock we can't provide
fn ioLockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
    return error.Canceled;
}

fn ioUnlockStderr(_: ?*anyopaque) void {}

// start from std's all-failing vtable and override only what the VM touches.
const io_vtable: std.Io.VTable = blk: {
    var v = std.Io.failing.vtable.*;
    v.operate = ioOperate;
    v.now = ioNow;
    v.clockResolution = ioClockResolution;
    v.sleep = ioSleep;
    v.crashHandler = ioCrashHandler;
    v.lockStderr = ioLockStderr;
    v.unlockStderr = ioUnlockStderr;
    break :blk v;
};

const serial_io: std.Io = .{ .userdata = null, .vtable = &io_vtable };

// A second IO used only as std's debug IO (for std.debug.print, which revo hits
// on a few error paths). std's default debug IO is a threaded stderr writer that
// doesn't exist on freestandin, and std.Io.failing's stderr path is literally
// unreachable, so we give std a real one that drains to the same sink. Unlike
// serial_io above, its lockStderr must return an actual File.Writer (std turns a
// Canceled lock into a panic), and swapCancelProtection must not be unreachable.
var dbg_fw: std.Io.File.Writer = undefined;
var dbg_fw_buf: [256]u8 = undefined;

fn dbgLockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
    // File.stderr() reads posix.STDERR_FILENO, which doesn't exist on
    // freestanding so we build the file by hand instead. ioOperate ignores
    // the handle and routes every write to the sink regardless
    const stderr_file: std.Io.File = .{ .handle = undefined, .flags = .{ .nonblocking = false } };
    dbg_fw = stderr_file.writerStreaming(debug_io, &dbg_fw_buf);
    return .{ .file_writer = &dbg_fw, .terminal_mode = .no_color };
}
fn dbgUnlockStderr(_: ?*anyopaque) void {
    dbg_fw.interface.flush() catch {};
}
fn dbgSwapCancel(_: ?*anyopaque, new: std.Io.CancelProtection) std.Io.CancelProtection {
    return new;
}

const debug_io_vtable: std.Io.VTable = blk: {
    var v = std.Io.failing.vtable.*;
    v.operate = ioOperate;
    v.now = ioNow;
    v.clockResolution = ioClockResolution;
    v.sleep = ioSleep;
    v.crashHandler = ioCrashHandler;
    v.lockStderr = dbgLockStderr;
    v.unlockStderr = dbgUnlockStderr;
    v.swapCancelProtection = dbgSwapCancel;
    break :blk v;
};

pub const debug_io: std.Io = .{ .userdata = null, .vtable = &debug_io_vtable };

// an unbuffered std.Io.Writer that drains straight to the sink, so we can render
// revo's own error reports (which write to a std.Io.Writer) onto the console
const SinkWriter = struct {
    interface: std.Io.Writer,

    fn init() SinkWriter {
        return .{ .interface = .{ .buffer = &.{}, .vtable = &.{ .drain = drain, .flush = flush }, .end = 0 } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = w;
        var total: usize = 0;
        for (data[0..data.len -| 1]) |s| {
            if (s.len > 0) emit(s);
            total += s.len;
        }
        const last = data[data.len -| 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            if (last.len > 0) emit(last);
        }
        total += last.len * splat;
        return total;
    }

    fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {}
};

const HostResult = revo.baselib.host.HostResult;
const Data = revo.Value;

// revo's only number type is f64 which is really fucking annoying
fn f64ToInt(comptime T: type, n: f64) ?T {
    if (!std.math.isFinite(n)) return null;
    // go through @floatFromInt for the bounds: maxInt(u64) isn't representable
    // as an f64 literal, so comparing against the comptime_int directly won't
    // even compile bruh
    const min_f: f64 = @floatFromInt(std.math.minInt(T));
    const max_f: f64 = @floatFromInt(std.math.maxInt(T));
    if (n < min_f or n > max_f) return null;
    return @intFromFloat(n);
}

// pass shit to revo
fn hostOutb(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const port = f64ToInt(u16, args[0].asNumOpt().?) orelse return HostResult.other("outb: port out of range");
    const val = f64ToInt(u8, args[1].asNumOpt().?) orelse return HostResult.other("outb: value out of range");
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (val),
          [p] "N{dx}" (port),
    );
    return HostResult.data(Data.new.nil());
}

// pass shit to revo
fn hostInb(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const port = f64ToInt(u16, args[0].asNumOpt().?) orelse return HostResult.other("inb: port out of range");
    const val = asm volatile ("inb %[p], %[r]"
        : [r] "={al}" (-> u8),
        : [p] "N{dx}" (port),
    );
    return HostResult.data(Data.new.num(val));
}

// pass shit to revo
fn hostPuts(args: []const revo.Value, vm: *revo.VM) anyerror!HostResult {
    const s = args[0].asString() orelse return HostResult.other("puts: not a string");
    emit(vm.stringValue(s));
    return HostResult.data(Data.new.nil());
}

// the actual framebuffer, the data layout feels pretty self explanatory
pub const Fb = struct {
    ptr: [*]u8,
    width: usize,
    height: usize,
    pitch: usize,
};
var g_fb: ?Fb = null;

fn hostFbWidth(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(if (g_fb) |fb| fb.width else 0));
}

fn hostFbHeight(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    return HostResult.data(Data.new.num(if (g_fb) |fb| fb.height else 0));
}

// color is 0xRRGGBB in the usual Limine 32-bpp layout
fn hostFillRect(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const fb = g_fb orelse return HostResult.data(Data.new.nil()); // no screen, no-op
    const x = f64ToInt(usize, args[0].asNumOpt().?) orelse return HostResult.other("fill_rect: bad x");
    const y = f64ToInt(usize, args[1].asNumOpt().?) orelse return HostResult.other("fill_rect: bad y");
    const w = f64ToInt(usize, args[2].asNumOpt().?) orelse return HostResult.other("fill_rect: bad w");
    const h = f64ToInt(usize, args[3].asNumOpt().?) orelse return HostResult.other("fill_rect: bad h");
    const color = f64ToInt(u32, args[4].asNumOpt().?) orelse return HostResult.other("fill_rect: bad color");

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

// mirror everything to serial
fn emit(bytes: []const u8) void {
    sink(bytes);
}

// shift the whole framebuffer up dy pixels and clear the freed rows
fn hostFbScroll(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const fb = g_fb orelse return HostResult.data(Data.new.nil());
    const dy = f64ToInt(usize, args[0].asNumOpt().?) orelse return HostResult.other("fb_scroll: bad dy");
    const color = f64ToInt(u32, args[1].asNumOpt().?) orelse return HostResult.other("fb_scroll: bad color");
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

pub const KernelOps = struct {
    phys_to_virt: *const fn (u64) u64,
    alloc_frame: *const fn () u64, // 0 on failure
    create_addrspace: *const fn () u64, // pml4 phys, 0 on failure (raw 64-bit entry copy incl. possible NX bit -> not f64-representable)
    run_process: *const fn (u64, u64, u64) void, // pml4, entry, ustack
    serial_next: *const fn () i64, // next mirrored serial byte, or -1 if empty
    elf_phys: u64,
    elf_size: u64,
};
var g_kops: ?KernelOps = null;

// mem_read(phys, size) -> value: read 1/2/4/8 bytes of physical memory
fn hostMemRead(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ops = g_kops orelse return HostResult.other("no kernel ops");
    const phys = f64ToInt(u64, args[0].asNumOpt().?) orelse return HostResult.other("mem_read: bad addr");
    const size = f64ToInt(u64, args[1].asNumOpt().?) orelse return HostResult.other("mem_read: bad size");
    const v = ops.phys_to_virt(phys);
    const val: u64 = switch (size) {
        1 => @as(*const u8, @ptrFromInt(v)).*,
        2 => @as(*align(1) const u16, @ptrFromInt(v)).*,
        4 => @as(*align(1) const u32, @ptrFromInt(v)).*,
        8 => @as(*align(1) const u64, @ptrFromInt(v)).*,
        else => return HostResult.other("mem_read: size must be 1/2/4/8"),
    };
    return HostResult.data(Data.new.num(val));
}

// mem_copy(dst_phys, src_phys, len): raw copy between physical regions
fn hostMemCopy(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ops = g_kops orelse return HostResult.other("no kernel ops");
    const dst = ops.phys_to_virt(f64ToInt(u64, args[0].asNumOpt().?) orelse return HostResult.other("mem_copy: bad dst"));
    const src = ops.phys_to_virt(f64ToInt(u64, args[1].asNumOpt().?) orelse return HostResult.other("mem_copy: bad src"));
    const len = f64ToInt(usize, args[2].asNumOpt().?) orelse return HostResult.other("mem_copy: bad len");
    @memcpy(@as([*]u8, @ptrFromInt(dst))[0..len], @as([*]const u8, @ptrFromInt(src))[0..len]);
    return HostResult.data(Data.new.nil());
}

// mem_zero(phys, len)
fn hostMemZero(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ops = g_kops orelse return HostResult.other("no kernel ops");
    const dst = ops.phys_to_virt(f64ToInt(u64, args[0].asNumOpt().?) orelse return HostResult.other("mem_zero: bad addr"));
    const len = f64ToInt(usize, args[1].asNumOpt().?) orelse return HostResult.other("mem_zero: bad len");
    @memset(@as([*]u8, @ptrFromInt(dst))[0..len], 0);
    return HostResult.data(Data.new.nil());
}

// mem_write(phys, val, size): write 1/2/4/8 bytes of physical memory
fn hostMemWrite(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ops = g_kops orelse return HostResult.other("no kernel ops");
    const phys = f64ToInt(u64, args[0].asNumOpt().?) orelse return HostResult.other("mem_write: bad addr");
    const val = f64ToInt(u64, args[1].asNumOpt().?) orelse return HostResult.other("mem_write: bad val");
    const size = f64ToInt(u64, args[2].asNumOpt().?) orelse return HostResult.other("mem_write: bad size");
    const v = ops.phys_to_virt(phys);
    switch (size) {
        1 => @as(*u8, @ptrFromInt(v)).* = @truncate(val),
        2 => @as(*align(1) u16, @ptrFromInt(v)).* = @truncate(val),
        4 => @as(*align(1) u32, @ptrFromInt(v)).* = @truncate(val),
        8 => @as(*align(1) u64, @ptrFromInt(v)).* = val,
        else => return HostResult.other("mem_write: size must be 1/2/4/8"),
    }
    return HostResult.data(Data.new.nil());
}

// invlpg(virt): flush one page from the TLB after remapping it
fn hostInvlpg(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const virt = f64ToInt(u64, args[0].asNumOpt().?) orelse return HostResult.other("invlpg: bad addr");
    asm volatile ("invlpg (%[v])"
        :
        : [v] "r" (virt),
        : .{ .memory = true });
    return HostResult.data(Data.new.nil());
}

fn hostFrameAlloc(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ops = g_kops orelse return HostResult.other("no kernel ops");
    return HostResult.data(Data.new.num(ops.alloc_frame()));
}

fn hostAsCreate(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ops = g_kops orelse return HostResult.other("no kernel ops");
    return HostResult.data(Data.new.num(ops.create_addrspace()));
}

fn hostProcRun(args: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ops = g_kops orelse return HostResult.other("no kernel ops");
    const as = f64ToInt(u64, args[0].asNumOpt().?) orelse return HostResult.other("proc_run: bad as");
    const entry = f64ToInt(u64, args[1].asNumOpt().?) orelse return HostResult.other("proc_run: bad entry");
    const ustack = f64ToInt(u64, args[2].asNumOpt().?) orelse return HostResult.other("proc_run: bad ustack");
    ops.run_process(as, entry, ustack);
    return HostResult.data(Data.new.nil());
}

// serial_next() -> byte or -1
fn hostSerialNext(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ops = g_kops orelse return HostResult.other("no kernel ops");
    return HostResult.data(Data.new.num(ops.serial_next()));
}

fn hostElfPhys(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ops = g_kops orelse return HostResult.other("no kernel ops");
    return HostResult.data(Data.new.num(ops.elf_phys));
}

fn hostElfSize(_: []const revo.Value, _: *revo.VM) anyerror!HostResult {
    const ops = g_kops orelse return HostResult.other("no kernel ops");
    return HostResult.data(Data.new.num(ops.elf_size));
}

fn registerPrimitives(vm: *revo.VM) !void {
    const define = revo.baselib.host.define;
    const T = revo.baselib.host.ParamType;
    try vm.registerGlobal("outb", try vm.installHost("outb", define(&[_]T{ .number, .number }, hostOutb)));
    try vm.registerGlobal("inb", try vm.installHost("inb", define(&[_]T{.number}, hostInb)));
    try vm.registerGlobal("serial_puts", try vm.installHost("serial_puts", define(&[_]T{.string}, hostPuts)));
    try vm.registerGlobal("fb_width", try vm.installHost("fb_width", define(&[_]T{}, hostFbWidth)));
    try vm.registerGlobal("fb_height", try vm.installHost("fb_height", define(&[_]T{}, hostFbHeight)));
    try vm.registerGlobal("fill_rect", try vm.installHost("fill_rect", define(&[_]T{ .number, .number, .number, .number, .number }, hostFillRect)));
    try vm.registerGlobal("fb_scroll", try vm.installHost("fb_scroll", define(&[_]T{ .number, .number }, hostFbScroll)));
    // low-level: memory + address spaces + process launch (revo's ELF loader)
    try vm.registerGlobal("mem_read", try vm.installHost("mem_read", define(&[_]T{ .number, .number }, hostMemRead)));
    try vm.registerGlobal("mem_copy", try vm.installHost("mem_copy", define(&[_]T{ .number, .number, .number }, hostMemCopy)));
    try vm.registerGlobal("mem_zero", try vm.installHost("mem_zero", define(&[_]T{ .number, .number }, hostMemZero)));
    try vm.registerGlobal("mem_write", try vm.installHost("mem_write", define(&[_]T{ .number, .number, .number }, hostMemWrite)));
    try vm.registerGlobal("invlpg", try vm.installHost("invlpg", define(&[_]T{.number}, hostInvlpg)));
    try vm.registerGlobal("frame_alloc", try vm.installHost("frame_alloc", define(&[_]T{}, hostFrameAlloc)));
    try vm.registerGlobal("as_create", try vm.installHost("as_create", define(&[_]T{}, hostAsCreate)));
    try vm.registerGlobal("proc_run", try vm.installHost("proc_run", define(&[_]T{ .number, .number, .number }, hostProcRun)));
    try vm.registerGlobal("serial_next", try vm.installHost("serial_next", define(&[_]T{}, hostSerialNext)));
    try vm.registerGlobal("elf_phys", try vm.installHost("elf_phys", define(&[_]T{}, hostElfPhys)));
    try vm.registerGlobal("elf_size", try vm.installHost("elf_size", define(&[_]T{}, hostElfSize)));
}

// the VM outlives boot() now, so we juts make this hoe static
var g_vm: ?*revo.VM = null;

const init_program = @embedFile("k_font") ++ "\n" ++
    @embedFile("k_console") ++ "\n" ++
    @embedFile("k_vmm") ++ "\n" ++
    @embedFile("k_proc") ++ "\n" ++
    @embedFile("k_shell") ++ "\n" ++
    @embedFile("k_input") ++ "\n" ++
    @embedFile("k_main");

pub fn boot(alloc: std.mem.Allocator, out: Sink, fb: ?Fb, ops: ?KernelOps) void {
    sink = out;
    g_fb = fb;
    g_kops = ops;

    // NOTE: we drive the VM directly (compile -> run) instead of the high-level
    // Runtime.eval wrapper, which has a latent type error in revo that only
    // trips when analyzed. same low-level path revo's own wasm entry uses.
    const VM = revo.VM;
    const vm = alloc.create(VM) catch {
        out("bridge: OOM creating VM\r\n");
        return;
    };
    vm.* = VM.init(.{
        .alloc = alloc,
        .io = serial_io,
        .argv = &.{},
        .diag_alloc = alloc,
    }) catch {
        out("bridge: VM.init failed\r\n");
        return;
    };
    out("bridge: revo VM up\r\n");

    registerPrimitives(vm) catch {
        out("bridge: registering primitives failed\r\n");
        return;
    };

    const build_result = revo.lang.build(vm, .{ .name = "kernel", .text = init_program }, .{}) catch {
        out("bridge: compile threw\r\n");
        return;
    };
    const artifact = switch (build_result) {
        .ok => |art| art,
        .err => |failure| {
            out("bridge: compile error: ");
            var sw = SinkWriter.init();
            revo.lang.renderError(alloc, &sw.interface, .{ .name = "kernel", .text = init_program }, failure) catch {};
            out("\r\n");
            return;
        },
    };

    // NOTE: on purpose we don't free artifact.instructions/spans cause on_key's
    //       bytecode lives in there and we call it for the life of the kernel
    vm.setProgramDebugInfo(artifact.spans, "", "kernel") catch {
        out("bridge: setProgramDebugInfo failed\r\n");
        return;
    };

    const eval_result = revo.run.runBytecodeReport(vm, "kernel", artifact.instructions) catch {
        out("bridge: eval threw\r\n");
        return;
    };
    switch (eval_result) {
        .ok => g_vm = vm, // handler is defined so hand the VM to the event loop
        .err => |failure| {
            out("\r\nbridge: runtime error: ");
            var sw = SinkWriter.init();
            failure.render(alloc, &sw.interface, init_program) catch {};
            out("\r\n");
        },
    }
}

// called from the boot event loop for each raw scancode
// hand it to revo's on_key
// runs in normal context (not the ISR), so allocation is fine here
// i think
pub fn onKey(scancode: u8) void {
    const vm = g_vm orelse return;
    const cb = vm.getGlobal("on_key") orelse return;
    if (cb.asFunction() == null) return;
    _ = vm.callFunctionParts(cb, null, &[_]revo.Value{revo.Value.new.num(scancode)}, null) catch {
        sink("bridge: on_key threw\r\n");
    };
    flushConsole(vm);
}

// render any serial output produced while handling the key
fn flushConsole(vm: *revo.VM) void {
    const f = vm.getGlobal("flush_console") orelse return;
    if (f.asFunction() == null) return;
    _ = vm.callFunctionParts(f, null, &.{}, null) catch {};
}
