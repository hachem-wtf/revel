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

// fan a multi-slice write payload out to the sink. mirrors the shape of std.Io's
// file_write_streaming request: an optional header, then `data`, whose LAST slice
// is repeated `splat` times. returns the total byte count written.
fn writeToSink(
    header: []const u8,
    data: []const []const u8,
    splat: usize,
) std.Io.Operation.FileWriteStreaming.Result {
    if (header.len > 0) sink(header);
    for (data[0 .. data.len -| 1]) |slice| {
        if (slice.len > 0) sink(slice);
    }
    const last = data[data.len -| 1];
    var i: usize = 0;
    while (i < splat) : (i += 1) {
        if (last.len > 0) sink(last);
    }

    var total: usize = header.len;
    for (data[0 .. data.len -| 1]) |slice| total += slice.len;
    total += last.len * splat;
    return total;
}

// every file write (stdout, stderr, whatever) routes to the serial port; we
// don't have a filesystem or multiple sinks yet, so there's nowhere else to go.
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

// no timer wired up yet, so time stands still. fine until we have the PIT/TSC.
fn ioNow(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
    return .{ .nanoseconds = 0 };
}

fn ioClockResolution(_: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    return .{ .nanoseconds = 1_000_000 };
}

// the scheduler parks fibers itself, it never needs us to actually block.
fn ioSleep(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {}

fn ioCrashHandler(_: ?*anyopaque) void {}

// eval captures its own errors into a buffer, so this is never reached; return
// Canceled rather than recursing into a stderr lock we can't provide.
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
// doesn't exist on freestanding, and std.Io.failing's stderr path is literally
// `unreachable` -- so we give std a real one that drains to the same sink. Unlike
// serial_io above, its lockStderr must return an actual File.Writer (std turns a
// Canceled lock into a panic), and swapCancelProtection must not be unreachable.
var dbg_fw: std.Io.File.Writer = undefined;
var dbg_fw_buf: [256]u8 = undefined;

fn dbgLockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
    // File.stderr() reads posix.STDERR_FILENO, which doesn't exist on
    // freestanding. Build the File by hand instead; ioOperate ignores the handle
    // and routes every write to the sink regardless.
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
// revo's own error reports (which write to a std.Io.Writer) onto the console.
const SinkWriter = struct {
    interface: std.Io.Writer,

    fn init() SinkWriter {
        return .{ .interface = .{ .buffer = &.{}, .vtable = &.{ .drain = drain, .flush = flush }, .end = 0 } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = w;
        var total: usize = 0;
        for (data[0 .. data.len -| 1]) |s| {
            if (s.len > 0) sink(s);
            total += s.len;
        }
        const last = data[data.len -| 1];
        var i: usize = 0;
        while (i < splat) : (i += 1) {
            if (last.len > 0) sink(last);
        }
        total += last.len * splat;
        return total;
    }

    fn flush(_: *std.Io.Writer) std.Io.Writer.Error!void {}
};

// bring up the VM on the kernel heap and run a revo program. this is the "hello
// world" that proves the whole stack: revo compiled for bare metal, our
// allocator feeding it, its stdout coming out our serial port.
pub fn run(alloc: std.mem.Allocator, out: Sink) void {
    sink = out;

    // NOTE: we drive the VM directly (compile -> run) instead of the high-level
    // Runtime.eval wrapper. that wrapper has a latent type error in revo (it
    // names module.EvalResult, which doesn't exist) that only trips when it's
    // actually analyzed -- we're the first caller. this is the same low-level
    // path revo's own wasm entry uses, so it's the well-trodden one anyway.
    const VM = revo.VM;
    const vm = alloc.create(VM) catch {
        out("bridge: OOM creating VM\r\n");
        return;
    };
    defer alloc.destroy(vm);
    vm.* = VM.init(.{
        .alloc = alloc,
        .io = serial_io,
        .argv = &.{},
        .diag_alloc = alloc,
    }) catch {
        out("bridge: VM.init failed\r\n");
        return;
    };
    defer vm.deinit();
    out("bridge: revo VM up\r\n");

    // a proper workout, not just a print: recursion (call frames + soft-float
    // arithmetic), string methods (real stdlib), tables, tuples, destructuring.
    const src =
        \\fn fib(n) do
        \\  if n < 2 n
        \\  else fib(n - 1) + fib(n - 2)
        \\end
        \\print("hello from revo")
        \\print("fib(10) =", fib(10))
        \\print("arith  =", 1 + 2 * 3, 10 / 4)
        \\print("string =", "revo":upper(), "KERNEL":lower())
        \\const arr = {10, 20, 30}
        \\print("table  =", arr, arr[0])
        \\const (a, b) = (3, 4)
        \\print("tuple  =", a + b)
    ;
    const build_result = revo.lang.build(vm, .{ .name = "kernel", .text = src }, .{}) catch {
        out("bridge: compile threw\r\n");
        return;
    };
    const artifact = switch (build_result) {
        .ok => |art| art,
        .err => {
            out("bridge: compile error\r\n");
            return;
        },
    };
    defer alloc.free(artifact.instructions);
    defer alloc.free(artifact.spans);

    vm.setProgramDebugInfo(artifact.spans, "", "kernel") catch {
        out("bridge: setProgramDebugInfo failed\r\n");
        return;
    };

    const eval_result = revo.module.runCompiledModuleReport(vm, "kernel", artifact.instructions) catch {
        out("bridge: eval threw\r\n");
        return;
    };
    switch (eval_result) {
        .ok => out("\r\nbridge: eval ok\r\n"),
        .err => |failure| {
            out("\r\nbridge: runtime error: ");
            var sw = SinkWriter.init();
            failure.render(alloc, &sw.interface, src) catch {};
            out("\r\n");
        },
    }
}
