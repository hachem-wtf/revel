// the embedded ring 3 programs, boot copies each to frames at startup
pub const Program = struct { name: []const u8, bytes: []const u8 };

pub const programs = [_]Program{
    .{ .name = "hexview", .bytes = @embedFile("user_hexview") },
    .{ .name = "calc", .bytes = @embedFile("user_calc") },
    .{ .name = "primes", .bytes = @embedFile("user_primes") },
};
