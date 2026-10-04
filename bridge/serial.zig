const std = @import("std");

pub const Sink = *const fn ([]const u8) void;
fn noopSink(_: []const u8) void {}
var sink: Sink = noopSink;

pub fn setSink(s: Sink) void {
    sink = s;
}

// mirror everything to serial
pub fn emit(bytes: []const u8) void {
    sink(bytes);
}

// note: returns the total byte count written
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

// no timer wired up yet
// #call me the time bender the way i fuck shit up
// todo: fine until we have the pit/tsc
fn ioNow(_: ?*anyopaque, _: std.Io.Clock) std.Io.Timestamp {
    return .{ .nanoseconds = 0 };
}

fn ioClockResolution(_: ?*anyopaque, _: std.Io.Clock) std.Io.Clock.ResolutionError!std.Io.Duration {
    return .{ .nanoseconds = 1_000_000 };
}

fn ioSleep(_: ?*anyopaque, _: std.Io.Timeout) std.Io.Cancelable!void {}

fn ioCrashHandler(_: ?*anyopaque) void {}

// eval captures its own errors into a buffer, so this is never reached lol
fn ioLockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
    return error.Canceled;
}

fn ioUnlockStderr(_: ?*anyopaque) void {}

const io_vtable: std.Io.VTable = blk: {
    var vtable = std.Io.failing.vtable.*;
    vtable.operate = ioOperate;
    vtable.now = ioNow;
    vtable.clockResolution = ioClockResolution;
    vtable.sleep = ioSleep;
    vtable.crashHandler = ioCrashHandler;
    vtable.lockStderr = ioLockStderr;
    vtable.unlockStderr = ioUnlockStderr;
    break :blk vtable;
};

pub const serial_io: std.Io = .{ .userdata = null, .vtable = &io_vtable };

var dbg_fw: std.Io.File.Writer = undefined;
var dbg_fw_buf: [256]u8 = undefined;

fn dbgLockStderr(_: ?*anyopaque, _: ?std.Io.Terminal.Mode) std.Io.Cancelable!std.Io.LockedStderr {
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
    var vtable = std.Io.failing.vtable.*;
    vtable.operate = ioOperate;
    vtable.now = ioNow;
    vtable.clockResolution = ioClockResolution;
    vtable.sleep = ioSleep;
    vtable.crashHandler = ioCrashHandler;
    vtable.lockStderr = dbgLockStderr;
    vtable.unlockStderr = dbgUnlockStderr;
    vtable.swapCancelProtection = dbgSwapCancel;
    break :blk vtable;
};

pub const debug_io: std.Io = .{ .userdata = null, .vtable = &debug_io_vtable };

// an unbuffered std.io.writer that drains straight to the sink, so we can render
// revos own error reports (which write to a std.io.writer) onto the console
pub const SinkWriter = struct {
    interface: std.Io.Writer,

    pub fn init() SinkWriter {
        return .{ .interface = .{ .buffer = &.{}, .vtable = &.{ .drain = drain, .flush = flush }, .end = 0 } };
    }

    fn drain(w: *std.Io.Writer, data: []const []const u8, splat: usize) std.Io.Writer.Error!usize {
        _ = w;
        var total: usize = 0;
        for (data[0..data.len -| 1]) |slice| {
            if (slice.len > 0) emit(slice);
            total += slice.len;
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
