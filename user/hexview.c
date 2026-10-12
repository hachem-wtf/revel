#include <stdio.h>
#include <unistd.h>
#include <fcntl.h>

#define PAGE 256
#define COLS 16

int main(int argc, char** argv)
{
    char prompt_name[64];
    const char* name;
    if (argc >= 2)
        name = argv[1];
    else
    {
        printf("hexview, type a filename\nfile: ");
        readline(prompt_name, 64);
        printf("\n");
        name = prompt_name;
    }

    int fd = open(name, O_RDONLY);
    if (fd < 0)
    {
        printf("no such file\n");
        return 1;
    }
    long size = lseek(fd, 0, SEEK_END);

    unsigned long offset = 0;
    char buffer[PAGE];

    for (;;)
    {
        lseek(fd, (long)offset, SEEK_SET);
        long count = read(fd, buffer, PAGE);

        printf("--- %s @ 0x%08lx / 0x%08lx ---\n", name, offset, (unsigned long)size);

        for (long row = 0; row < count; row += COLS)
        {
            printf("%08lx: ", offset + (unsigned long)row);
            for (int column = 0; column < COLS; column++)
            {
                if (row + column < count)
                    printf("%02x ", (unsigned char)buffer[row + column]);
                else
                    printf("   ");
            }

            printf(" ");
            for (int column = 0; column < COLS && row + column < count; column++)
            {
                char character = buffer[row + column];
                putchar((character >= 32 && character < 127) ? character : '.');
            }
            printf("\n");
        }

        printf("[n]ext [p]rev [q]uit (or up/down arrows) > ");
        int key = getchar();
        if (key == 27) // ESC
        {
            getchar();
            int final = getchar();
            if (final == 'A')
                key = 'p';
            else if (final == 'B')
                key = 'n';
        }

        printf("\n");
        if (key == 'q')
            break;
        if (key == 'n' && offset + PAGE < (unsigned long)size)
            offset += PAGE;
        if (key == 'p' && offset >= PAGE)
            offset -= PAGE;
    }

    close(fd);
    return 0;
}
