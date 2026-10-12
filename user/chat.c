#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>

int main(int argc, char** argv)
{
    if (argc < 2)
    {
        printf("usage: run chat <path>\n");
        return 1;
    }

    const char* path = argv[1];
    int fd = open(path, O_RDONLY);
    if (fd < 0)
    {
        printf("chat: %s: cannot open\n", path);
        return 1;
    }

    char buffer[256];
    long bytes_read;
    while ((bytes_read = read(fd, buffer, sizeof(buffer))) > 0)
        write(1, buffer, (unsigned long)bytes_read);

    close(fd);
    return 0;
}
