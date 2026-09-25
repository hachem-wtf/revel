// ring3 entry + the syscall boundary
// drop user mode with iretq, and come back to the kernel
//
// see: - https://wiki.osdev.org/System_Calls
//      - https://wiki.osdev.org/Getting_to_Ring_3

const serial = @import("serial.zig");
const idt = @import("idt.zig");
const vmm = @import("vmm.zig");
const pmm = @import("pmm.zig");

// where enterUserAsm parked the kernel stack
export var kernel_return_rsp: u64 = 0;
// args to enterUserAsm, passed via globals so it can stay a clean naked fn :flushed:
export var g_user_entry: u64 = 0;
export var g_user_stack: u64 = 0;

// what the syscall stub leaves on the stack (GP regs it pushed, then the frame the CPU pushed on the int 0x80)
// rax holds the syscall number
pub const SyscallFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,
};

// install the int 0x80 gate at DPL 3 so ring3 code is allowed to invoke it.
pub fn installSyscall() void {
    idt.setGate(0x80, @intFromPtr(&syscallStub), 3);
}

// drop to ring 3 at g_user_entry with stack g_user_stack
// returns (via the exit syscall s longjmp) once the program calls exit
pub fn enterUser(entry: u64, ustack: u64) void {
    g_user_entry = entry;
    g_user_stack = ustack;
    // this is the truest most correct statement ever
    // get this man a true
    asm volatile ("call enterUserAsm" ::: .{ .memory = true, .rax = true, .rcx = true, .rdx = true, .rsi = true, .rdi = true, .r8 = true, .r9 = true, .r10 = true, .r11 = true });
}

export fn enterUserAsm() callconv(.naked) void {
    asm volatile (
        \\ push %rbx
        \\ push %rbp
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ mov %rsp, kernel_return_rsp(%rip)
        \\ pushq $0x23              // SS = user data (0x20) | RPL 3
        \\ mov g_user_stack(%rip), %rax
        \\ push %rax                // user RSP
        \\ pushq $0x2               // RFLAGS: reserved bit only (IF=0 for the demo)
        \\ pushq $0x1b              // CS = user code (0x18) | RPL 3
        \\ mov g_user_entry(%rip), %rax
        \\ push %rax                // RIP = entry
        \\ iretq
    );
}

export fn syscallStub() callconv(.naked) void {
    asm volatile (
        \\ push %rax
        \\ push %rbx
        \\ push %rcx
        \\ push %rdx
        \\ push %rsi
        \\ push %rdi
        \\ push %rbp
        \\ push %r8
        \\ push %r9
        \\ push %r10
        \\ push %r11
        \\ push %r12
        \\ push %r13
        \\ push %r14
        \\ push %r15
        \\ mov %rsp, %rdi
        \\ call syscallHandler       // rax = 0 continue, 1 exit
        \\ test %rax, %rax
        \\ jnz 1f
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ pop %r11
        \\ pop %r10
        \\ pop %r9
        \\ pop %r8
        \\ pop %rbp
        \\ pop %rdi
        \\ pop %rsi
        \\ pop %rdx
        \\ pop %rcx
        \\ pop %rbx
        \\ pop %rax
        \\ iretq
        \\ 1:
        \\ mov kernel_return_rsp(%rip), %rsp
        \\ pop %r15
        \\ pop %r14
        \\ pop %r13
        \\ pop %r12
        \\ pop %rbp
        \\ pop %rbx
        \\ ret
    );
}

pub fn runProcess(pml4: u64, entry: u64, ustack: u64) void {
    const prev = vmm.activePml4();
    vmm.loadPml4(pml4);
    enterUser(entry, ustack);
    vmm.loadPml4(prev);
}

export fn syscallHandler(frame: *SyscallFrame) callconv(.c) u64 {
    switch (frame.rax) {
        0 => { // exit(code): code in rdi
            return 1; // tell the stub to unwind back into the kernel
        },
        1 => { // write(ptr, len): rdi = user pointer, rsi = length
            const len = frame.rsi;
            // the process's address space is active during the syscall, so the
            // kernel can read the user pointer directly. cap the length so a
            // bogus arg can't run us off into unmapped memory.
            if (len > 0 and len <= 4096) {
                const bytes: [*]const u8 = @ptrFromInt(frame.rdi);
                serial.write(bytes[0..len]); // mirrored -> the revo console renders it
            }
            frame.rax = len; // syscall return value
            return 0;
        },
        else => {
            serial.write("[syscall] unknown\r\n");
            return 0;
        },
    }
}

//   mov $1,%eax   ; int $0x80 (hello)
//   xor %eax,%eax ; int $0x80 (exit)
pub fn runTestProgram() void {
    const as = vmm.createAddressSpace() orelse return;
    const code_frame = pmm.alloc() orelse return;
    const stack_frame = pmm.alloc() orelse return;
    const code_virt: u64 = 0x400000; // 4 MiB
    const stack_virt: u64 = 0x800000; // 8 MiB
    _ = vmm.map(as, code_virt, code_frame, vmm.WRITE | vmm.USER);
    _ = vmm.map(as, stack_virt, stack_frame, vmm.WRITE | vmm.USER);

    const code = [_]u8{ 0xB8, 0x01, 0x00, 0x00, 0x00, 0xCD, 0x80, 0x31, 0xC0, 0xCD, 0x80 };
    const dst: [*]u8 = @ptrFromInt(pmm.physToVirt(code_frame)); // write via HHDM
    @memcpy(dst[0..code.len], &code);

    const prev = vmm.activePml4();
    vmm.loadPml4(as);
    serial.write("[user] entering ring 3...\r\n");
    enterUser(code_virt, stack_virt + pmm.PAGE_SIZE);
    vmm.loadPml4(prev);
    serial.write("[user] back in the kernel, continuing\r\n");
}
