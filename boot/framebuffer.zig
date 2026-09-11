// linear framebuffer type shi you feel me?
// see: https://wiki.osdev.org/Limine_Bare_Bones

const limine = @import("limine.zig");

pub const Framebuffer = limine.Framebuffer;

// the request placed in .limine_requests so the loader finds and fills it
// idk why this sounds vaguely erotic, like yeah fill me harder lol
export var request: limine.FramebufferRequest linksection(".limine_requests") = .{};

// the response pointer is written by Limine before we run, so read it through a
// volatile pointer or the optimizer assumes it's still null
pub fn get() ?*Framebuffer {
    const req: *volatile limine.FramebufferRequest = &request;
    const resp = req.response orelse return null;
    if (resp.framebuffer_count == 0) return null;
    return resp.framebuffers.?[0];
}

// assumes the usual Limine RGB 32-bpp layout im sure i wont forget about this layout
// later and it wont fuck me over
pub fn putpixel(fb: *Framebuffer, x: usize, y: usize, color: u32) void {
    const pixel: *align(1) u32 = @ptrCast(fb.address + y * fb.pitch + x * 4);
    pixel.* = color;
}
