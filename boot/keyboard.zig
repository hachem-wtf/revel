// top half of the PS/2 keyboard driver.
// the IRQ1 handler calls onIrq and reads the raw scancode out
// of the controller and drops it in a ring buffer. thats ALLLLLL it does
// no decoding, no allocation, nothing that could (should) fault or reenter
// the only reason this exists is because the interrupt handler is not a safe
// spot to execute revo code and shit can break easily and i am NOT going to debug
// it so its just better to do it like this.
//
// since there is just one producer (ISR) and one consumer (the event loop)
// i dont need to make a lock, the ISR just moves the tail and the loop just
// moves the head

const port = @import("port.zig");

const DATA_PORT: u16 = 0x60;
const SIZE: usize = 256; // u8 indices wrap mod 256 for free

var buf: [SIZE]u8 = undefined;
var head: u8 = 0; // next slot the loop will read
var tail: u8 = 0; // next slot the ISR will write

// called from the IRQ1 handler. read the scancode (which also ACKs the
// controller so it'll send the next one) and enqueue it, dropping it on the
// floor if the buffer is somehow full.
pub fn onIrq() void {
    const code = port.inb(DATA_PORT);
    const t: *volatile u8 = &tail;
    const h: *volatile u8 = &head;
    if (t.* +% 1 == h.*) return; // full, drop
    buf[t.*] = code;
    t.* +%= 1;
}

// called from the event loop. next queued scancode, or null if empty.
pub fn pop() ?u8 {
    const t: *volatile u8 = &tail;
    const h: *volatile u8 = &head;
    if (h.* == t.*) return null;
    const code = buf[h.*];
    h.* +%= 1;
    return code;
}
