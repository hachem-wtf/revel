// hexview, a ring 3 program that dumps a file from the revel fs. nav is n/p/q
// since the keyboard only gives us decoded ascii, no arrow keys yet

#include "user.h"

static const char HEX[] = "0123456789abcdef";

static void put_hex8(unsigned char byte)
{
    char digits[2] = { HEX[byte >> 4], HEX[byte & 15] };
    sys_write(digits, 2);
}

static void put_hex32(unsigned long value)
{
    char digits[8];
    for (int nibble = 0; nibble < 8; nibble++)
        digits[nibble] = HEX[(value >> ((7 - nibble) * 4)) & 15];
    sys_write(digits, 8);
}

#define PAGE 256
#define COLS 16

void _start(void)
{
    put("hexview, type a filename\nfile: ");
    char name[64];
    read_line(name, 64);
    put("\n");

    long size = sys_fs_size(name);
    if (size < 0)
    {
        put("no such file\n");
        sys_exit(1);
    }

    unsigned long offset = 0;
    char buffer[PAGE];
    for (;;)
    {
        long count = sys_fs_read(name, offset, buffer, PAGE);

        put("--- ");
        put(name);
        put(" @ 0x");
        put_hex32(offset);
        put(" / 0x");
        put_hex32((unsigned long)size);
        put(" ---\n");

        for (long row = 0; row < count; row += COLS)
        {
            put_hex32(offset + (unsigned long)row);
            put(": ");
            for (int column = 0; column < COLS; column++)
            {
                if (row + column < count)
                {
                    put_hex8((unsigned char)buffer[row + column]);
                    sys_write(" ", 1);
                }
                else
                    put("   ");
            }
            put(" ");
            for (int column = 0; column < COLS && row + column < count; column++)
            {
                char character = buffer[row + column];
                if (character >= 32 && character < 127)
                    sys_write(&character, 1);
                else
                    sys_write(".", 1);
            }
            put("\n");
        }

        put("[n]ext [p]rev [q]uit > ");
        char key = (char)sys_read();
        put("\n");
        if (key == 'q')
            break;
        if (key == 'n' && offset + PAGE < (unsigned long)size)
            offset += PAGE;
        if (key == 'p' && offset >= PAGE)
            offset -= PAGE;
    }

    sys_exit(0);
}
