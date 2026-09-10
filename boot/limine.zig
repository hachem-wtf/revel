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
