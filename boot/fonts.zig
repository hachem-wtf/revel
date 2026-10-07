// js loading fonts from host disk
pub const Font = struct { name: []const u8, bytes: []const u8 };
pub const fonts = [_]Font{
    .{ .name = "vga16.psf", .bytes = @embedFile("font_vga16") },
    .{ .name = "vga8.psf", .bytes = @embedFile("font_vga8") },
    .{ .name = "sun16.psf", .bytes = @embedFile("font_sun16") },
    .{ .name = "acorn8.psf", .bytes = @embedFile("font_acorn8") },
    .{ .name = "pearl8.psf", .bytes = @embedFile("font_pearl8") },
    .{ .name = "dejavu.ttf", .bytes = @embedFile("font_dejavu") },
    .{ .name = "terminess.ttf", .bytes = @embedFile("font_terminess") },
};
