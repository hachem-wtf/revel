#ifndef _UNISTD_H
#define _UNISTD_H

#include <stddef.h>

#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

long read(int fd, void* buffer, size_t length);
long write(int fd, const void* buffer, size_t length);
int close(int fd);
long lseek(int fd, long offset, int whence);

void* sbrk(long increment);
int brk(void* address);

#endif
