#include "user.h"

void _start(const char* arg, unsigned long arglen)
{
    if (arglen == 0 || arglen >= 120)
    {
        put("usage: run save <path>\n");
        sys_exit(1);
    }

    char name[128];
    for (unsigned long i = 0; i < arglen; i++)
        name[i] = arg[i];
    name[arglen] = 0;

    long fd = sys_open(name, O_CREAT | O_TRUNC | O_WRONLY);
    if (fd < 0)
    {
        put("save: ");
        put(name);
        put(": cannot open\n");
        sys_exit(1);
    }

    put("saving to ");
    put(name);
    put(" -- type lines, a single . saves\n");

    for (;;)
    {
        char line[256];
        int n = read_line(line, 256);
        put("\n");
        if (n == 1 && line[0] == '.')
            break;
        sys_write(fd, line, (unsigned long)n);
        sys_write(fd, "\n", 1);
    }

    sys_close(fd);
    put("saved ");
    put(name);
    put("\n");
    sys_exit(0);
}
