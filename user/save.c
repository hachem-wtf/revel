#include "user.h"

void _start(const char* arg, unsigned long arglen)
{
    if (arglen == 0 || arglen >= 64)
    {
        put("usage: run save <path>\n");
        sys_exit(1);
    }

    char name[64];
    for (unsigned long i = 0; i < arglen; i++)
        name[i] = arg[i];
    name[arglen] = 0;

    put("saving to ");
    put(name);
    put(" -- type lines, a single . saves\n");

    char buffer[4096];
    int length = 0;
    for (;;)
    {
        char line[256];
        int n = read_line(line, 256);
        put("\n");
        if (n == 1 && line[0] == '.')
            break;
        for (int i = 0; i < n && length < 4000; i++)
            buffer[length++] = line[i];
        if (length < 4000)
            buffer[length++] = '\n';
    }

    if (sys_fs_write(name, buffer, (unsigned long)length))
    {
        put("saved ");
        put(name);
        put("\n");
    }
    else
        put("write failed\n");

    sys_exit(0);
}
