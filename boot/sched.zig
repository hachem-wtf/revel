// tiny preemptive shitty round robin scheduler

const std = @import("std");
const Frame = @import("regs.zig").Frame;
const vmm = @import("vmm.zig");
const gdt = @import("gdt.zig");
const bridge = @import("bridge");

const MAX_TASKS = 8;
const KSTACK_SIZE = 16 * 1024;

const State = enum { free, ready, dead, blocked };

const Task = struct {
    frame: Frame = std.mem.zeroes(Frame),
    cr3: u64 = 0,
    kstack_top: u64 = 0, // tss rsp0 for this task, 0 for the ring 0 kernel task
    state: State = .free,
};

var tasks: [MAX_TASKS]Task = @splat(.{});
var kstacks: [MAX_TASKS][KSTACK_SIZE]u8 align(16) = undefined;
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
        var f = std.mem.zeroes(Frame);
        f.rip = entry;
        f.cs = 0x1b; // user code (0x18) | rpl 3
        f.rflags = 0x202; // reserved bit + if=1, so its preemptible
        f.rsp = ustack;
        f.ss = 0x23; // user data (0x20) | rpl 3
        f.rdi = arg; // _start(arg_ptr, arg_len), the sysv first two args
        f.rsi = arglen;
        tasks[i] = .{
            .frame = f,
            .cr3 = cr3,
            .kstack_top = @intFromPtr(&kstacks[i]) + KSTACK_SIZE,
            .state = .ready,
        };
        return;
    }
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
    return @intFromEnum(tasks[i].state);
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
    const e = proc_exited_flag;
    proc_exited_flag = false;
    return e;
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
        tasks[task].frame.rax = byte;
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
    var n: usize = 0;
    while (n < MAX_TASKS) : (n += 1) {
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
