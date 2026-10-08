#include "user.h"

void _start(const char* arg, unsigned long arglen)
{
    if (arglen == 0)
    {
        put("usage: run chat <path>\n");
        sys_exit(1);
    }

    char path[128];
    unsigned long i = 0;
    for (; i < arglen && i < sizeof(path) - 1; i++)
        path[i] = arg[i];
    path[i] = 0;

    long fd = sys_open(path, 0);
    if (fd < 0)
    {
        put("chat: ");
        put(path);
        put(": cannot open\n");
        sys_exit(1);
    }

    char buffer[256];
    long n;
    while ((n = sys_read(fd, buffer, sizeof(buffer))) > 0)
        sys_write(1, buffer, (unsigned long)n);

    sys_close(fd);
    sys_exit(0);
}
