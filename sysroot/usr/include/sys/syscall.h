#ifndef _SYS_SYSCALL_H
#define _SYS_SYSCALL_H

#define SYS_exit  0
#define SYS_write 1
#define SYS_read  2
#define SYS_open  7
#define SYS_close 8
#define SYS_lseek 9
#define SYS_brk   10
#define SYS_sbrk  11

static inline long __syscall1(long number, long a1)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(number), "D"(a1) : "memory");
    return result;
}

static inline long __syscall2(long number, long a1, long a2)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(number), "D"(a1), "S"(a2) : "memory");
    return result;
}

static inline long __syscall3(long number, long a1, long a2, long a3)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(number), "D"(a1), "S"(a2), "d"(a3) : "memory");
    return result;
}

#endif
