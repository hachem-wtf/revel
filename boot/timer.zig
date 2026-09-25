// PIT channel 0 tick counter
// configuring the PIT itself (outb to 0x43/0x40) is done in revo (kernel
// `pit_init`), since it's just port writes the VM can drive

var ticks: u64 = 0;

// called from the IRQ0 handler
pub fn onIrq() void {
    const t: *volatile u64 = &ticks;
    t.* +%= 1;
}

// called from the event loop
pub fn now() u64 {
    const t: *volatile u64 = &ticks;
    return t.*;
}
