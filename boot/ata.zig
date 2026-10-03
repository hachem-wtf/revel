// ata pio driver, primary bus master drive, 28 bit lba
//
// this is the dumbest most simple most retartded possible block device driver
// it busy polls the status port and shovels one sector at a time through the 16
// bit data port. no dma no interrupts no second drive. its slow but the whole point
// is that revo builds a real filesystem on top of these two calls (read/write a 512 byte sector) so
// i need to rewrite this when im not drunk (never gonna happen)
//
// see: https://wiki.osdev.org/ATA_PIO_Mode

const port = @import("port.zig");
const serial = @import("serial.zig");

pub const SECTOR = 512;

// primary bus io ports
const DATA = 0x1F0;
const FEATURES = 0x1F1; // error on read
const SECCOUNT = 0x1F2;
const LBA_LO = 0x1F3;
const LBA_MID = 0x1F4;
const LBA_HI = 0x1F5;
const DRIVE = 0x1F6;
const CMD = 0x1F7; // status on read
const CTRL = 0x3F6; // alt status / device control

// status bits
const ST_ERR = 0x01;
const ST_DRQ = 0x08; // data request, drive wants a word moved
const ST_DRDY = 0x40;
const ST_BSY = 0x80;

const CMD_READ = 0x20;
const CMD_WRITE = 0x30;
const CMD_FLUSH = 0xE7;
const CMD_IDENTIFY = 0xEC;

var g_present = false;
var g_sectors: u64 = 0;

pub fn present() bool {
    return g_present;
}

pub fn sectorCount() u64 {
    return g_sectors;
}

// reading the alt status 4 times burns ~400ns, the spec wants that gap after a
// command before the status bits mean anything
fn delay400() void {
    _ = port.inb(CTRL);
    _ = port.inb(CTRL);
    _ = port.inb(CTRL);
    _ = port.inb(CTRL);
}

// spin until bsy drops
// returns false if it never does (dead bus)
fn waitNotBusy() bool {
    var spins: u32 = 0;
    while (spins < 1_000_000) : (spins += 1) {
        if (port.inb(CMD) & ST_BSY == 0) return true;
    }
    return false;
}

// spin until the drive is ready to move a word (drq set)
// false on error/timeout
fn waitDrq() bool {
    var spins: u32 = 0;
    while (spins < 1_000_000) : (spins += 1) {
        const st = port.inb(CMD);
        if (st & ST_ERR != 0) return false;
        if (st & ST_BSY == 0 and st & ST_DRQ != 0) return true;
    }
    return false;
}

// select master and load the lba + a one sector count
fn selectSector(lba: u28) void {
    port.outb(DRIVE, 0xE0 | @as(u8, @truncate((lba >> 24) & 0x0F)));
    port.outb(FEATURES, 0);
    port.outb(SECCOUNT, 1);
    port.outb(LBA_LO, @truncate(lba & 0xFF));
    port.outb(LBA_MID, @truncate((lba >> 8) & 0xFF));
    port.outb(LBA_HI, @truncate((lba >> 16) & 0xFF));
}

// probe the primary master with identify, the floating bus reads status
// 0xFF, a present drive clears bsy and coughs up 256 words of identify data,
// words 60/61 hold the 28 bit sector count
pub fn init() void {
    // a nonexistent bus floats high, bail before we wait a million spins on it
    if (port.inb(CMD) == 0xFF) {
        serial.write("ata: no drive on primary bus\r\n");
        return;
    }

    port.outb(DRIVE, 0xA0); // master
    delay400();
    port.outb(SECCOUNT, 0);
    port.outb(LBA_LO, 0);
    port.outb(LBA_MID, 0);
    port.outb(LBA_HI, 0);
    port.outb(CMD, CMD_IDENTIFY);
    delay400();

    if (port.inb(CMD) == 0) {
        serial.write("ata: primary master absent\r\n");
        return;
    }
    if (!waitDrq()) {
        serial.write("ata: identify failed\r\n");
        return;
    }

    var id: [256]u16 = undefined;
    for (&id) |*w| w.* = port.inw(DATA);

    g_sectors = (@as(u64, id[61]) << 16) | id[60];
    g_present = true;
    serial.write("ata: primary master, sectors=");
    serial.writeDec(g_sectors);
    serial.write("\r\n");
}

// read one 512 byte sector at lba into buf
pub fn read(lba: u28, buf: *[SECTOR]u8) bool {
    if (!g_present) return false;
    if (!waitNotBusy()) return false;
    selectSector(lba);
    port.outb(CMD, CMD_READ);
    if (!waitDrq()) return false;
    var i: usize = 0;
    while (i < SECTOR) : (i += 2) {
        const w = port.inw(DATA);
        buf[i] = @truncate(w & 0xFF);
        buf[i + 1] = @truncate(w >> 8);
    }
    return true;
}

// write one 512 byte sector from buf to lba, then flush the drive cache so it
// actually hits the image and survives a reboot, yk, like an actual file system
pub fn write(lba: u28, buf: *const [SECTOR]u8) bool {
    if (!g_present) return false;
    if (!waitNotBusy()) return false;
    selectSector(lba);
    port.outb(CMD, CMD_WRITE);
    if (!waitDrq()) return false;
    var i: usize = 0;
    while (i < SECTOR) : (i += 2) {
        const w = @as(u16, buf[i]) | (@as(u16, buf[i + 1]) << 8);
        port.outw(DATA, w);
    }
    port.outb(CMD, CMD_FLUSH);
    _ = waitNotBusy();
    return true;
}
