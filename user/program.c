static long sys_write(const char* buffer, unsigned long buffer_length)
{
    long ret;
    __asm__ volatile("int $0x80" : "=a"(ret) : "a"(1L), "D"(buffer), "S"(buffer_length) : "memory");
    return ret;
}

static long sys_read(void)
{
    long ret;
    __asm__ volatile("int $0x80" : "=a"(ret) : "a"(2L) : "memory");
    return ret;
}

static void sys_exit(long code)
{
    __asm__ volatile("int $0x80" : : "a"(0L), "D"(code) : "memory");
    for (;;);
}

static void put(const char* string)
{
    unsigned long n = 0;
    while (string[n])
        n++;
    sys_write(string, n);
}

void _start(void)
{
    put("what's your name? ");
    char name[64];
    int name_length = 0;

    for (;;)
    {
        char character = (char)sys_read();
        if (character == '\n')
            break;

        if (character == '\b')
        {
            if (name_length > 0)
            {
                name_length--;
                sys_write("\b \b", 3);
            }

            continue;
        }

        if (name_length < 63)
        {
            name[name_length++] = character;
            sys_write(&character, 1);
        }
    }

    put("\noue va te faire foutre ");
    sys_write(name, name_length);
    put("\n");
    sys_exit(0);
}
