// linear framebuffer type shi you feel me?
// see: https://wiki.osdev.org/Limine_Bare_Bones

const limine = @import("limine.zig");

pub const Framebuffer = limine.Framebuffer;

// the request placed in .limine_requests so the loader finds and fills it
// idk why this sounds vaguely erotic, like yeah fill me harder lol
export var request: limine.FramebufferRequest linksection(".limine_requests") = .{};

// the response pointer is written by limine before we run, so read it through a
// volatile pointer or the optimizer assumes its still null
pub fn get() ?*Framebuffer {
    const req: *volatile limine.FramebufferRequest = &request;
    const resp = req.response orelse return null;
    if (resp.framebuffer_count == 0) return null;
    return resp.framebuffers.?[0];
}
