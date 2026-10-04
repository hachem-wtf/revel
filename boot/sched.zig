// tiny preemptive round robin scheduler. a task is a saved frame + cr3 + kernel
// stack, task 0 is the kernel event loop. the pit tick swaps the interrupted
// frame for the next ready tasks and iretqs in, which covers ring 0 and ring 3
// alike. each task has its own kernel stack so preempting one mid syscall (e.g. a
// read() parked on sti/hlt) doesnt clobber anothers rsp0

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
var spawn_count: u64 = 0;
// the one task currently blocked in read(), if any
var blocked_reader: ?usize = null;
// the "foreground" task that owns keyboard input (set when a task first reads,
// cleared when it exits). keystrokes route to it, into stdin_buf when it isnt
// currently blocked, so nothing is lost between its reads. else the shell
var foreground: ?usize = null;
var stdin_buf: [64]u8 = undefined;
var stdin_head: usize = 0;
var stdin_tail: usize = 0;

fn stdinPush(byte: u8) void {
    if (stdin_tail -% stdin_head >= stdin_buf.len) return; // full, drop
    stdin_buf[stdin_tail % stdin_buf.len] = byte;
    stdin_tail +%= 1;
}
fn stdinPop() ?u8 {
    if (stdin_head == stdin_tail) return null;
    const byte = stdin_buf[stdin_head % stdin_buf.len];
    stdin_head +%= 1;
    return byte;
}

// task 0 = the kernel/event loop, running in whatever cr3 boot set up
pub fn init(kernel_cr3: u64) void {
    tasks[0] = .{ .cr3 = kernel_cr3, .state = .ready, .kstack_top = 0 };
    current = 0;
}

// queue a ring 3 process. it starts running the next time the scheduler picks
// it (the tick copies its initial frame onto the stack and iretqs in). rdi is
// seeded with a small per spawn id so demo programs can tell instances apart
pub fn spawn(cr3: u64, entry: u64, ustack: u64) void {
    var i: usize = 1;
    while (i < MAX_TASKS) : (i += 1) {
        if (tasks[i].state != .free) continue;
        var f = std.mem.zeroes(Frame);
        f.rip = entry;
        f.cs = 0x1b; // user code (0x18) | rpl 3
        f.rflags = 0x202; // reserved bit + if=1, so its preemptible
        f.rsp = ustack;
        f.ss = 0x23; // user data (0x20) | rpl 3
        f.rdi = spawn_count;
        spawn_count += 1;
        tasks[i] = .{
            .frame = f,
            .cr3 = cr3,
            .kstack_top = @intFromPtr(&kstacks[i]) + KSTACK_SIZE,
            .state = .ready,
        };
        return;
    }
}

// number of live user processes (ready or blocked), excluding the kernel task
pub fn procCount() u64 {
    var count: u64 = 0;
    var i: usize = 1;
    while (i < MAX_TASKS) : (i += 1) {
        if (tasks[i].state == .ready or tasks[i].state == .blocked) count += 1;
    }
    return count;
}

var proc_exited_flag: bool = false;

// mark the running process dead. it then sti+hlts, the next tick reclaims the
// slot and switches away, never returning here
pub fn exitCurrent() void {
    if (current != 0) {
        tasks[current].state = .dead;
        proc_exited_flag = true; // the kernel task reprints the prompt on seeing this
        if (foreground == current) { // hand keyboard back to the shell
            foreground = null;
            stdin_head = 0;
            stdin_tail = 0;
        }
    }
}

// did a process exit since last checked? (consumed once.)
pub fn takeProcExited() bool {
    const e = proc_exited_flag;
    proc_exited_flag = false;
    return e;
}

// called at the top of read(): the caller becomes the foreground reader. returns
// a buffered byte if one is waiting (so read() neednt block), else null
pub fn readReady() ?u8 {
    foreground = current;
    return stdinPop();
}

// block the running task in read(). `resume_frame` is a context that iretqs
// straight back to just after the processs int 0x80, so when input arrives we
// set its rax and mark it ready, and the scheduler resumes it there
pub fn blockCurrentOnRead(resume_frame: Frame) void {
    if (current == 0) return; // the kernel task never blocks like this
    tasks[current].frame = resume_frame;
    tasks[current].state = .blocked;
    blocked_reader = current;
}

// route one input byte. if a task is blocked in read(), wake it with the byte
// else if a foreground reader exists, buffer it for its next read(). returns
// false only when nothing wants it (so the caller feeds the shell instead)
pub fn deliverInput(byte: u8) bool {
    if (blocked_reader) |task| {
        tasks[task].frame.rax = byte; // read()s return value
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

// the preemption point, called from the pit irq with the interrupted frame
pub fn tick(frame: *Frame) void {
    // dont preempt task 0 mid vm call, the shared fiber cant be re-entered
    if (bridge.vmBusy()) return;

    if (tasks[current].state == .dead) {
        tasks[current].state = .free; // reclaim, dont bother saving its context
    } else if (tasks[current].state == .blocked) {
        // keep the resume frame saved by blockcurrentonread, dont clobber it
    } else {
        tasks[current].frame = frame.*; // freeze the current task
    }

    // round robin to the next ready task
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
    // if the current task cant continue (dead/blocked) and nothing else is
    // ready, fall back to the kernel task (0), which is always ready
    if (tasks[current].state != .ready and next == current) next = 0;
    if (next == current) return; // nothing else to run, keep going

    current = next;
    frame.* = tasks[current].frame;
    vmm.loadPml4(tasks[current].cr3);
    if (tasks[current].kstack_top != 0) gdt.setKernelStack(tasks[current].kstack_top);
}
