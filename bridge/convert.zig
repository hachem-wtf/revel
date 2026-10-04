const std = @import("std");
const revo = @import("revo");

pub const HostResult = revo.baselib.host.HostResult;
pub const Data = revo.Value;

// revos only number type is f64 which is really fucking annoying
pub fn f64ToInt(comptime T: type, n: f64) ?T {
    if (!std.math.isFinite(n)) return null;
    const min_f: f64 = @floatFromInt(std.math.minInt(T));
    const max_f: f64 = @floatFromInt(std.math.maxInt(T));
    if (n < min_f or n > max_f) return null;
    return @intFromFloat(n);
}

pub fn argInt(comptime T: type, args: []const revo.Value, i: usize) ?T {
    return f64ToInt(T, args[i].asNumOpt().?);
}
