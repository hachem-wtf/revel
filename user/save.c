#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        printf("usage: run save <path>\n");
        return 1;
    }

    const char* name = argv[1];
    int fd = open(name, O_CREAT | O_TRUNC | O_WRONLY);
    if (fd < 0)
    {
        printf("save: %s: cannot open\n", name);
        return 1;
    }

    printf("saving to %s -- type lines, a single . saves\n", name);

    for (;;)
    {
        char line[256];
        int bytes_read = readline(line, 256);
        printf("\n");
        if (bytes_read == 1 && line[0] == '.')
            break;
        write(fd, line, (unsigned long)bytes_read);
        write(fd, "\n", 1);
    }

    close(fd);
    printf("saved %s\n", name);
    return 0;
}
