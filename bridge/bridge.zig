// so the thing is right, revo isnt really that low level and we need to have a
// thin bridge to translate shit over. its just to setup the vm, serial ports,
// heap shit like that

const std = @import("std");
const revo = @import("revo");
const serial = @import("serial.zig");
const hosts = @import("hosts.zig");

pub const Sink = serial.Sink;
pub const debug_io = serial.debug_io;
pub const Fb = hosts.Fb;
pub const KernelOps = hosts.KernelOps;

// the vm outlives boot() now, so we juts make this hoe static
var g_vm: ?*revo.VM = null;

// NOTE: ORDER MATTERS
const init_program = blk: {
    var s: []const u8 = @embedFile("k_font") ++ "\n" ++
        @embedFile("k_console") ++ "\n" ++
        @embedFile("k_vmm") ++ "\n" ++
        @embedFile("k_fs") ++ "\n" ++
        @embedFile("k_vfs") ++ "\n" ++
        @embedFile("k_seed") ++ "\n";

    // gils shit
    const gils_embedded = .{ "gils", "ed" };
    for (gils_embedded) |g| s = s ++ @embedFile("k_gils_" ++ g) ++ "\n";

    s = s ++ @embedFile("k_proc") ++ "\n" ++
        @embedFile("k_shell") ++ "\n" ++
        @embedFile("k_input") ++ "\n" ++
        @embedFile("k_main");
    break :blk s;
};

pub fn boot(alloc: std.mem.Allocator, out: Sink, fb: ?Fb, ops: ?KernelOps) void {
    serial.setSink(out);
    hosts.setFb(fb);
    hosts.setKops(ops);

    // note: we drive the vm directly (compile -> run) instead of the high level
    // runtime.eval wrapper, which has a latent type error in revo that only
    // trips when analyzed. same low level path revos own wasm entry uses
    const VM = revo.VM;
    const vm = alloc.create(VM) catch {
        out("bridge: OOM creating VM\r\n");
        return;
    };
    vm.* = VM.init(.{
        .alloc = alloc,
        .io = serial.serial_io,
        .argv = &.{},
        .diag_alloc = alloc,
    }) catch {
        out("bridge: VM.init failed\r\n");
        return;
    };
    out("bridge: revo VM up\r\n");

    hosts.passShitToRevo(vm) catch {
        out("bridge: registering primitives failed\r\n");
        return;
    };

    const build_result = revo.lang.build(vm, .{ .name = "kernel", .text = init_program }, .{}) catch {
        out("bridge: compile threw\r\n");
        return;
    };
    const artifact = switch (build_result) {
        .ok => |art| art,
        .err => |failure| {
            out("bridge: compile error: ");
            var sw = serial.SinkWriter.init();
            revo.lang.renderError(alloc, &sw.interface, .{ .name = "kernel", .text = init_program }, failure, .{}) catch {};
            out("\r\n");
            return;
        },
    };

    // note: on purpose we dont free artifact.instructions/spans cause on_keys
    //       bytecode lives in there and we call it for the life of the kernel
    vm.setProgramDebugInfo(artifact.spans, "", "kernel") catch {
        out("bridge: setProgramDebugInfo failed\r\n");
        return;
    };

    const eval_result = revo.run.runBytecodeReport(vm, "kernel", artifact.instructions) catch {
        out("bridge: eval threw\r\n");
        return;
    };
    switch (eval_result) {
        .ok => g_vm = vm, // handler is defined so hand the vm to the event loop
        .err => |failure| {
            out("\r\nbridge: runtime error: ");
            var sw = serial.SinkWriter.init();
            failure.render(alloc, &sw.interface, init_program, false) catch {};
            out("\r\n");
        },
    }
}

// called from the boot event loop for each raw scancode
// hand it to revos on_key
// runs in normal context (not the isr), so allocation is fine here
// i think
pub fn onKey(scancode: u8) void {
    const vm = g_vm orelse return;
    const cb = vm.getGlobal("on_key") orelse return;
    if (cb.asFunction() == null) return;
    g_vm_running = true;
    defer g_vm_running = false;
    _ = vm.callFunctionParts(cb, null, &[_]revo.Value{revo.Value.new.num(scancode)}, null) catch |e| {
        serial.emit("bridge: on_key threw: ");
        serial.emit(@errorName(e));
        serial.emit("\r\n");
    };
    flushConsole(vm);
}

fn flushConsole(vm: *revo.VM) void {
    const func = vm.getGlobal("flush_console") orelse return;
    if (func.asFunction() == null) return;
    _ = vm.callFunctionParts(func, null, &.{}, null) catch {};
}

pub fn onTick(ticks: u64) void {
    const vm = g_vm orelse return;
    const cb = vm.getGlobal("on_tick") orelse return;
    if (cb.asFunction() == null) return;
    g_vm_running = true;
    defer g_vm_running = false;
    _ = vm.callFunctionParts(cb, null, &[_]revo.Value{revo.Value.new.num(ticks)}, null) catch {};
}

var g_vm_running: bool = false;
pub fn vmBusy() bool {
    return g_vm_running;
}

pub fn fsSize(name: []const u8) i64 {
    const vm = g_vm orelse return -1;
    const func = vm.getGlobal("fs_size") orelse return -1;
    const name_val = vm.ownValueString(name) catch return -1;
    g_vm_running = true;
    defer g_vm_running = false;
    const r = vm.callFunctionParts(func, null, &[_]revo.Value{name_val}, null) catch return -1;
    return @intFromFloat(r.asNumOpt() orelse return -1);
}

pub fn fsReadInto(name: []const u8, offset: u64, dst: []u8) usize {
    const vm = g_vm orelse return 0;
    const func = vm.getGlobal("fs_read_bytes") orelse return 0;
    const name_val = vm.ownValueString(name) catch return 0;
    g_vm_running = true;
    defer g_vm_running = false;
    const r = vm.callFunctionParts(func, null, &[_]revo.Value{
        name_val,
        revo.Value.new.num(offset),
        revo.Value.new.num(dst.len),
    }, null) catch return 0;
    const sid = r.asString() orelse return 0;
    const bytes = vm.stringValue(sid);
    const n = @min(bytes.len, dst.len);
    @memcpy(dst[0..n], bytes[0..n]);
    return n;
}

pub fn fsStore(name: []const u8, data: []const u8) bool {
    const vm = g_vm orelse return false;
    const func = vm.getGlobal("fs_store") orelse return false;
    const name_val = vm.ownValueString(name) catch return false;
    const data_val = vm.ownValueString(data) catch return false;
    g_vm_running = true;
    defer g_vm_running = false;
    const r = vm.callFunctionParts(func, null, &[_]revo.Value{ name_val, data_val }, null) catch return false;
    return (r.asNumOpt() orelse 0) == 1;
}
