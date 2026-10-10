// this is a minimal 16550 uart driver for com1, this is mainly going
// to be used for debugging since its really simple to setup
// fun fact: i was drunk when i wrote this
//
// see: https://wiki.osdev.org/Serial_Ports

const COM1: u16 = 0x3F8;

// 16550 register offsets from the base port
const REG_DATA: u16 = 0; // rx/tx
const REG_IER: u16 = 1; // interrupt enable
const REG_FCR: u16 = 2; // fifo control (write)
const REG_LCR: u16 = 3; // line control
const REG_MCR: u16 = 4; // modem control
const REG_LSR: u16 = 5; // line status

const LCR_DLAB: u8 = 0x80; // divisor latch access bit
const LCR_8N1: u8 = 0x03; // 8 data bits
const LSR_THR_EMPTY: u8 = 0x20; // transmit holding register empty
const FCR_ENABLE: u8 = 0xC7; // enable + clear fifos
const MCR_READY: u8 = 0x0B; // dtr + rts + out2
const BAUD_38400_LOW: u8 = 0x03; // divisor 3 low byte

const MIRROR_SIZE = 1 << 15; // 32 kib, power of two

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
// fifo on
// idempotent so it should be relatively safe to call
// from the panic handler
pub fn init() void {
    outb(COM1 + REG_IER, 0x00); // no interrupts
    outb(COM1 + REG_LCR, LCR_DLAB); // the next two writes set the baud divisor
    outb(COM1 + REG_DATA, BAUD_38400_LOW); // divisor low byte
    outb(COM1 + REG_IER, 0x00); // divisor high byte
    outb(COM1 + REG_LCR, LCR_8N1); // dlab off
    outb(COM1 + REG_FCR, FCR_ENABLE);
    outb(COM1 + REG_MCR, MCR_READY);
}

// every byte we send to the port is also captured here so the revo
// console can render the same stream
var mirror: [MIRROR_SIZE]u8 = undefined;
var m_head: usize = 0; // next byte the console will render
var m_tail: usize = 0; // next slot putc will write

// com1+5 (bit 5) = transmit holding register and
//                  spin until its clear to send
fn putc(byte: u8) void {
    while (inb(COM1 + REG_LSR) & LSR_THR_EMPTY == 0) {}
    outb(COM1 + REG_DATA, byte);
    mirror[m_tail & (mirror.len - 1)] = byte;
    m_tail +%= 1;
}

// next un rendered byte, or null if caught up. if the console fell far enough
// behind to lap the ring, drop the oldest bytes
pub fn mirrorNext() ?u8 {
    if (m_head == m_tail) return null;
    if (m_tail -% m_head > mirror.len) m_head = m_tail -% mirror.len;
    const byte = mirror[m_head & (mirror.len - 1)];
    m_head +%= 1;
    return byte;
}

// a raw serial console needs \r\n, but revo (and most sane code) emits bare \n
// inject the \r ourselves, skipping it when the \n already has one so existing
// "\r\n" strings dont turn into "\r\r\n"
pub fn write(bytes: []const u8) void {
    var prev: u8 = 0;
    for (bytes) |byte| {
        if (byte == '\n' and prev != '\r') putc('\r');
        putc(byte);
        prev = byte;
    }
}

// dump a u64 as decimal. handy for "usable: n mib" type logging
pub fn writeDec(value: u64) void {
    if (value == 0) return putc('0');
    var buf: [20]u8 = undefined;
    var i: usize = buf.len;
    var remaining = value;
    while (remaining > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(remaining % 10));
        remaining /= 10;
    }
    write(buf[i..]);
}

// dump a u64 as 0x prefixed 16 digit hex
pub fn writeHex(value: u64) void {
    const digits = "0123456789abcdef";
    var buf: [18]u8 = undefined;
    buf[0] = '0';
    buf[1] = 'x';
    var i: usize = 0;
    while (i < 16) : (i += 1) {
        const shift: u6 = @intCast((15 - i) * 4);
        buf[2 + i] = digits[(value >> shift) & 0xF];
    }
    write(&buf);
}
