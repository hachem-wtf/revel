#include <unistd.h>
#include <fcntl.h>
#include <sys/syscall.h>

long read(int fd, void* buffer, size_t length)
{
    return __syscall3(SYS_read, fd, (long)buffer, (long)length);
}

long write(int fd, const void* buffer, size_t length)
{
    return __syscall3(SYS_write, fd, (long)buffer, (long)length);
}

int open(const char* path, int flags)
{
    return (int)__syscall2(SYS_open, (long)path, flags);
}

int close(int fd)
{
    return (int)__syscall1(SYS_close, fd);
}

long lseek(int fd, long offset, int whence)
{
    return __syscall3(SYS_lseek, fd, offset, whence);
}

void* sbrk(long increment)
{
    return (void*)__syscall1(SYS_sbrk, increment);
}

int brk(void* address)
{
    return (int)__syscall1(SYS_brk, (long)address);
}
