#include <stdlib.h>

extern int main(int argc, char** argv);

void _start(const char* arg, unsigned long arglen)
{
    static char arg_buffer[256];
    char* argv[3];
    int argc = 1;
    argv[0] = "";

    if (arglen > 0)
    {
        unsigned long count = arglen;
        if (count > sizeof(arg_buffer) - 1)
            count = sizeof(arg_buffer) - 1;
        for (unsigned long i = 0; i < count; i++)
            arg_buffer[i] = arg[i];
        arg_buffer[count] = 0;
        argv[1] = arg_buffer;
        argc = 2;
    }
    else
        argv[1] = NULL;

    argv[argc] = NULL;
    exit(main(argc, argv));
}
