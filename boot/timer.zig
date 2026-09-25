// pit channel 0 tick counter
// configuring the pit itself (outb to 0x43/0x40) is done in revo (kernel
// `pit_init`), since its just port writes the vm can drive

var ticks: u64 = 0;

// called from the irq0 handler
pub fn onIrq() void {
    const ticks_ptr: *volatile u64 = &ticks;
    ticks_ptr.* +%= 1;
}

// called from the event loop
pub fn now() u64 {
    const ticks_ptr: *volatile u64 = &ticks;
    return ticks_ptr.*;
}
