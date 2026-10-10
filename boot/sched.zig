// tiny preemptive shitty round robin scheduler

const std = @import("std");
const Frame = @import("regs.zig").Frame;
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");
const gdt = @import("gdt.zig");
const bridge = @import("bridge");

const MAX_TASKS = 8;
const KSTACK_SIZE = 16 * 1024;
const MAX_FDS = 8;
const MAX_PATH = 128;

// user heap lives here in the gap between the program and the arg/stack
const HEAP_BASE: u64 = 0x1000_0000;

const State = enum { free, ready, dead, blocked };

// file descriptor not "foid decimator"
pub const FdKind = enum { closed, keyboard, console, file };
pub const Fd = struct {
    kind: FdKind = .closed,
    offset: u64 = 0,
    path_len: usize = 0,
    path: [MAX_PATH]u8 = @splat(0),
};

const Task = struct {
    frame: Frame = std.mem.zeroes(Frame),
    cr3: u64 = 0,
    kstack_top: u64 = 0, // tss rsp0 for this task, 0 for the ring 0 kernel task
    state: State = .free,
    brk_cur: u64 = 0, // the program break, top of the user heap
    brk_top: u64 = 0, // first page above the break thats actually mapped
};

var tasks: [MAX_TASKS]Task = @splat(.{});
var kstacks: [MAX_TASKS][KSTACK_SIZE]u8 align(16) = undefined;
var fdtabs: [MAX_TASKS][MAX_FDS]Fd = @splat(@splat(.{}));
var current: usize = 0;
var blocked_reader: ?usize = null;

var foreground: ?usize = null;
var stdin_buf: [64]u8 = undefined;
var stdin_head: usize = 0;
var stdin_tail: usize = 0;

fn stdinPush(byte: u8) void {
    if (stdin_tail -% stdin_head >= stdin_buf.len) return;
    stdin_buf[stdin_tail % stdin_buf.len] = byte;
    stdin_tail +%= 1;
}
fn stdinPop() ?u8 {
    if (stdin_head == stdin_tail) return null;
    const byte = stdin_buf[stdin_head % stdin_buf.len];
    stdin_head +%= 1;
    return byte;
}

// task 0 = the kernel/event loop running in whatever cr3 boot set up
pub fn init(kernel_cr3: u64) void {
    tasks[0] = .{ .cr3 = kernel_cr3, .state = .ready, .kstack_top = 0 };
    current = 0;
}

pub fn spawn(cr3: u64, entry: u64, ustack: u64, arg: u64, arglen: u64) void {
    var i: usize = 1;
    while (i < MAX_TASKS) : (i += 1) {
        if (tasks[i].state != .free) continue;
        const rpl_user = 3; // low two selector bits request ring 3
        const rflags_init = (1 << 1) | (1 << 9); // reserved bit + interrupt enable (preemptible)
        var frame = std.mem.zeroes(Frame);
        frame.rip = entry;
        frame.cs = @as(u64, gdt.USER_CODE) | rpl_user;
        frame.rflags = rflags_init;
        frame.rsp = ustack;
        frame.ss = @as(u64, gdt.USER_DATA) | rpl_user;
        frame.rdi = arg; // _start(arg_ptr, arg_len) the sysv first two args
        frame.rsi = arglen;
        tasks[i] = .{
            .frame = frame,
            .cr3 = cr3,
            .kstack_top = @intFromPtr(&kstacks[i]) + KSTACK_SIZE,
            .state = .ready,
            .brk_cur = HEAP_BASE,
            .brk_top = HEAP_BASE,
        };
        initFds(i);
        return;
    }
}

const USER_PAGE: u64 = vmm.WRITE | vmm.USER;

// map heap pages until everything below target is present
// false on oom
fn growHeap(task: *Task, target: u64) bool {
    while (task.brk_top < target) {
        const phys = pmm.alloc() orelse return false;
        // zero it so we never hand ring 3 whatever the fuck was in that frame before
        const page: [*]u8 = @ptrFromInt(pmm.physToVirt(phys));
        @memset(page[0..pmm.PAGE_SIZE], 0);
        if (!vmm.map(task.cr3, task.brk_top, phys, USER_PAGE)) {
            pmm.free(phys);
            return false;
        }
        task.brk_top += pmm.PAGE_SIZE;
    }
    return true;
}

// move the break to addr
pub fn brk(addr: u64) i64 {
    if (current == 0 or addr < HEAP_BASE) return -1;
    const task = &tasks[current];
    if (addr > task.brk_cur and !growHeap(task, addr)) return -1;
    task.brk_cur = addr;
    return @intCast(addr);
}

// move the break by increment
pub fn sbrk(increment: i64) i64 {
    if (current == 0) return -1;
    const task = &tasks[current];
    const old = task.brk_cur;
    const want: i64 = @as(i64, @intCast(old)) + increment;
    if (want < @as(i64, @intCast(HEAP_BASE))) return -1;
    const new_brk: u64 = @intCast(want);
    if (new_brk > old and !growHeap(task, new_brk)) return -1;
    task.brk_cur = new_brk;
    return @intCast(old);
}

// stdin at keyboard
fn initFds(i: usize) void {
    for (&fdtabs[i]) |*slot| slot.* = .{};
    fdtabs[i][0].kind = .keyboard;
    fdtabs[i][1].kind = .console;
    fdtabs[i][2].kind = .console;
}

// foid decimator open
pub fn fdOpen(path: []const u8) i64 {
    var i: usize = 3;
    while (i < MAX_FDS) : (i += 1) {
        const slot = &fdtabs[current][i];
        if (slot.kind == .closed) {
            slot.kind = .file;
            slot.offset = 0;
            const count = @min(path.len, MAX_PATH);
            @memcpy(slot.path[0..count], path[0..count]);
            slot.path_len = count;
            return @intCast(i);
        }
    }
    return -1;
}

// foid decimator get
pub fn fdGet(fd: i64) ?*Fd {
    if (fd < 0 or fd >= MAX_FDS) return null;
    const slot = &fdtabs[current][@intCast(fd)];
    if (slot.kind == .closed) return null;
    return slot;
}

// foid decimator close
pub fn fdClose(fd: i64) i64 {
    const slot = fdGet(fd) orelse return -1;
    slot.kind = .closed;
    return 0;
}

pub fn procCount() u64 {
    var count: u64 = 0;
    var i: usize = 1;
    while (i < MAX_TASKS) : (i += 1) {
        if (tasks[i].state == .ready or tasks[i].state == .blocked) count += 1;
    }
    return count;
}

// task table size + per slot state
// state is 0 free, 1 ready, 2 dead, 3 blocked
pub fn taskMax() u64 {
    return MAX_TASKS;
}
pub fn taskState(i: u64) u64 {
    if (i >= MAX_TASKS) return 0;
    return @backingInt(tasks[i].state);
}

var proc_exited_flag: bool = false;

// mark the running process dead then sti+hlts
pub fn exitCurrent() void {
    if (current != 0) {
        tasks[current].state = .dead;
        proc_exited_flag = true;
        if (foreground == current) {
            foreground = null;
            stdin_head = 0;
            stdin_tail = 0;
        }
    }
}

pub fn takeProcExited() bool {
    const exited = proc_exited_flag;
    proc_exited_flag = false;
    return exited;
}

pub fn readReady() ?u8 {
    foreground = current;
    return stdinPop();
}

pub fn blockCurrentOnRead(resume_frame: Frame) void {
    if (current == 0) return; // the kernel task never blocks like this
    tasks[current].frame = resume_frame;
    tasks[current].state = .blocked;
    blocked_reader = current;
}

pub fn deliverInput(byte: u8) bool {
    if (blocked_reader) |task| {
        stdinPush(byte);
        tasks[task].state = .ready;
        blocked_reader = null;
        return true;
    }
    if (foreground != null) {
        stdinPush(byte);
        return true;
    }
    return false;
}

pub fn tick(frame: *Frame) void {
    if (bridge.vmBusy()) return;

    if (tasks[current].state == .dead) {
        tasks[current].state = .free;
    } else if (tasks[current].state == .blocked) {
        // dont clobber it you bitch
    } else {
        tasks[current].frame = frame.*;
    }

    var next = current;
    var i = current;
    var count: usize = 0;
    while (count < MAX_TASKS) : (count += 1) {
        i = (i + 1) % MAX_TASKS;
        if (tasks[i].state == .ready) {
            next = i;
            break;
        }
    }

    if (tasks[current].state != .ready and next == current) next = 0;
    if (next == current) return;

    current = next;
    frame.* = tasks[current].frame;
    vmm.loadPml4(tasks[current].cr3);
    if (tasks[current].kstack_top != 0) gdt.setKernelStack(tasks[current].kstack_top);
}
