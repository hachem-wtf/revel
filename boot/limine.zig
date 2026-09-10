// Limine scans the loaded image for these magic numbers,
// BaseRevision is a handshake, essentially we ask limine
// for rev 3, and if it supports it, limine zeros it out
pub const BaseRevision = extern struct {
    magic0: u64 = 0xf9562b2d5c95a6c8,
    magic1: u64 = 0x6a7b384944536bdc,
    revision: u64,

    pub fn init(revision: u64) BaseRevision {
        return .{ .revision = revision };
    }
};

// Bracketing markers, they are pretty optional but when
// we add proper limine requests, having these here comes
// handy
pub const RequestsStartMarker = extern struct {
    m0: u64 = 0xf6b8f4b39de7d1ae,
    m1: u64 = 0xfab91a6940fcb9cf,
    m2: u64 = 0x785c6ed015d3e316,
    m3: u64 = 0x181e920a7852b9d9,
};

pub const RequestsEndMarker = extern struct {
    m0: u64 = 0xadc0e0531bb10d03,
    m1: u64 = 0x9572709f31764c62,
};

// Every request id starts with this common magic, then two request-specific
// words. Limine scans .limine_requests for these and fills in `response`.
fn requestId(a: u64, b: u64) [4]u64 {
    return .{ 0xc7b1dd30df4c8b88, 0x0a82e883a194f07b, a, b };
}

// this comes from the limine spec
// you can see it in the header files
pub const Framebuffer = extern struct {
    address: [*]u8,
    width: u64,
    height: u64,
    pitch: u64, // bytes per row (not always width*bpp/8)
    bpp: u16, // bits per pixel
    memory_model: u8, // 1 = RGB
    red_mask_size: u8,
    red_mask_shift: u8,
    green_mask_size: u8,
    green_mask_shift: u8,
    blue_mask_size: u8,
    blue_mask_shift: u8,
    // 7 bytes of padding land here (extern-struct alignment before edid_size)
    edid_size: u64,
    edid: ?*anyopaque,
    // response revision 1 and up, unused for now:
    mode_count: u64,
    modes: ?*anyopaque,
};

pub const FramebufferResponse = extern struct {
    revision: u64,
    framebuffer_count: u64,
    framebuffers: ?[*]*Framebuffer,
};

pub const FramebufferRequest = extern struct {
    id: [4]u64 = requestId(0x9d5827dcd881dd75, 0xa3148604f6fab11b),
    revision: u64 = 0,
    response: ?*FramebufferResponse = null,
};
