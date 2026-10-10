pub const Program = struct { name: []const u8, bytes: []const u8 };
pub const programs = [_]Program{
    .{ .name = "hexview", .bytes = @embedFile("user_hexview") },
    .{ .name = "calc", .bytes = @embedFile("user_calc") },
    .{ .name = "primes", .bytes = @embedFile("user_primes") },
    .{ .name = "save", .bytes = @embedFile("user_save") },
    .{ .name = "chat", .bytes = @embedFile("user_chat") },
    .{ .name = "membrk", .bytes = @embedFile("user_membrk") },
};
