// x86 port I/O
//
// these are pretty important cause all drivers which rely
// on serial rely on these 2 instructions so

pub inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

pub inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

// a throwaway write to an unused port, ~1us. some 8259s need a beat between
// back-to-back command writes on slow hardware; harmless on QEMU.
pub inline fn wait() void {
    outb(0x80, 0);
}
