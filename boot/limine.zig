// Limine scans the loaded image for these magic numbers, BaseRevision is 
// a handshake, essentially we ask limine for rev 3, and if it supports it, 
// limine zeros it out
pub const BaseRevision = extern struct {
    magic0: u64 = 0xf9562b2d5c95a6c8,
    magic1: u64 = 0x6a7b384944536bdc,
    revision: u64,

    pub fn init(revision: u64) BaseRevision {
        return .{ .revision = revision };
    }
};

// bracketing markers, they are pretty optional but when we add proper 
// limine requests, having these here comes handy
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

// every request id starts with this common magic, then two request specific
// words, bootloader scans .limine_requests for these and fills in `response`
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

// ask limine for a bigger bootstrap stack than its ~64 KiB default cause
// revo's VM init builds a large struct on the stack and runs a fat recursive
// descent parser to register its stdlib, which page faults the machine
pub const StackSizeResponse = extern struct {
    revision: u64,
};

pub const StackSizeRequest = extern struct {
    id: [4]u64 = requestId(0x224ef0460a8e8926, 0xe1cb0fc25f46ea3d),
    revision: u64 = 0,
    response: ?*StackSizeResponse = null,
    stack_size: u64,
};

// HHDM = higher-half direct map, limine linearly maps ALL of physical memory
// starting at `offset`, so any physical address p is reachable at p + offset
// This is how we touch physical frames without setting up our own page tables
// and this is how my hypothetical future girlfriend should touch my pointer
pub const HhdmResponse = extern struct {
    revision: u64,
    offset: u64,
};

pub const HhdmRequest = extern struct {
    id: [4]u64 = requestId(0x48dcf1cb8ad2b852, 0x63984e959a98244b),
    revision: u64 = 0,
    response: ?*HhdmResponse = null,
};

// what each region of physical memory is
// only `usable` (0) is ours to hand out freely
// the rest belongs to firmware and other stingy shits
pub const MemoryType = enum(u64) {
    usable = 0,
    reserved = 1,
    acpi_reclaimable = 2,
    acpi_nvs = 3,
    bad = 4,
    bootloader_reclaimable = 5,
    kernel_and_modules = 6,
    framebuffer = 7,
    _,
};

pub const MemoryMapEntry = extern struct {
    base: u64,
    length: u64,
    type: MemoryType,
};

// NOTE: `entries` is an array of POINTERS to entries, not the entries inline
// NOTE: i will forget this
pub const MemoryMapResponse = extern struct {
    revision: u64,
    entry_count: u64,
    entries: ?[*]*MemoryMapEntry,
};

pub const MemoryMapRequest = extern struct {
    id: [4]u64 = requestId(0x67cf3d9d378a806f, 0xe304acdfc50c3c62),
    revision: u64 = 0,
    response: ?*MemoryMapResponse = null,
};
