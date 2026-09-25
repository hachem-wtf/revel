// top half of the ps/2 keyboard driver
// the irq1 handler calls onirq and reads the raw scancode out
// of the controller and drops it in a ring buffer. thats allllll it does
// no decoding, no allocation, nothing that could (should) fault or reenter
// the only reason this exists is because the interrupt handler is not a safe
// spot to execute revo code and shit can break easily and i am not going to debug
// it so its just better to do it like this
//
// since there is just one producer (isr) and one consumer (the event loop)
// i dont need to make a lock, the isr just moves the tail and the loop just
// moves the head

const port = @import("port.zig");

const DATA_PORT: u16 = 0x60;
const SIZE: usize = 256; // u8 indices wrap mod 256 for free

var buf: [SIZE]u8 = undefined;
var head: u8 = 0; // next slot the loop will read
var tail: u8 = 0; // next slot the isr will write

// called from the irq1 handler. read the scancode (which also acks the
// controller so itll send the next one) and enqueue it, dropping it on the
// floor if the buffer is somehow full
pub fn onIrq() void {
    const code = port.inb(DATA_PORT);
    const tail_ptr: *volatile u8 = &tail;
    const head_ptr: *volatile u8 = &head;
    if (tail_ptr.* +% 1 == head_ptr.*) return; // full, drop
    buf[tail_ptr.*] = code;
    tail_ptr.* +%= 1;
}

// called from the event loop. next queued scancode, or null if empty
pub fn pop() ?u8 {
    const tail_ptr: *volatile u8 = &tail;
    const head_ptr: *volatile u8 = &head;
    if (head_ptr.* == tail_ptr.*) return null;
    const code = buf[head_ptr.*];
    head_ptr.* +%= 1;
    return code;
}
