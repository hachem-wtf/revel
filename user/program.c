static long sys_write(const char* buffer, unsigned long buffer_size)
{
    long ret;
    __asm__ volatile("int $0x80" : "=a"(ret) : "a"(1L), "D"(buffer), "S"(buffer_size) : "memory");
    return ret;
}
static void sys_exit(long code)
{
    __asm__ volatile("int $0x80" : : "a"(0L), "D"(code) : "memory");
    for (;;);
}

void _start(void)
{
    const char* message = "wassup shawty\n";
    unsigned long message_length = 0;
    while (message[message_length])
        message_length++;

    sys_write(message, message_length);
    sys_exit(0);
}
