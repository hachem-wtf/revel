// This is a minimal 16550 UART driver for COM1, this is 
// mainly going to be used for debugging since its really 
// simple to setup. Fun fact: i was drunk when i wrote this 
//
// see: https://wiki.osdev.org/Serial_Ports

const COM1: u16 = 0x3F8;

inline fn outb(port: u16, val: u8) void {
    asm volatile ("outb %[val], %[port]"
        :
        : [val] "{al}" (val),
          [port] "N{dx}" (port),
    );
}

inline fn inb(port: u16) u8 {
    return asm volatile ("inb %[port], %[result]"
        : [result] "={al}" (-> u8),
        : [port] "N{dx}" (port),
    );
}

// 38400 buard
// 8 data bits
// no parity
// one stop bit
// FIFO on
// Idempotent so it should be relatively safe to call
// from the panic handler.
pub fn init() void {
    outb(COM1 + 1, 0x00); // no interrupts
    outb(COM1 + 3, 0x80); // DLAB on: the next two writes set the baud divisor
    outb(COM1 + 0, 0x03); // divisor 3 -> 38400 baud (low byte)
    outb(COM1 + 1, 0x00); // divisor high byte
    outb(COM1 + 3, 0x03); // DLAB off, 8N1
    outb(COM1 + 2, 0xC7); // enable + clear FIFOs, 14-byte trigger
    outb(COM1 + 4, 0x0B); // RTS/DSR set
}

// COM1+5 (bit 5) = transmit holding register and 
//                  spin until it's clear to send
fn putc(c: u8) void {
    while (inb(COM1 + 5) & 0x20 == 0) {}
    outb(COM1, c);
}

pub fn write(s: []const u8) void {
    for (s) |c| putc(c);
}
