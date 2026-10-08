#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define O_WRONLY 1
#define O_CREAT  0x40
#define O_TRUNC  0x200
#define O_APPEND 0x400

static long sys_write(long fd, const char* buffer, unsigned long length)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(1L), "D"(fd), "S"(buffer), "d"(length) : "memory");
    return result;
}

static long sys_read(long fd, char* buffer, unsigned long length)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(2L), "D"(fd), "S"(buffer), "d"(length) : "memory");
    return result;
}

static long sys_open(const char* path, long flags)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(7L), "D"(path), "S"(flags) : "memory");
    return result;
}

static long sys_close(long fd)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(8L), "D"(fd) : "memory");
    return result;
}

static long sys_lseek(long fd, long offset, long whence)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(9L), "D"(fd), "S"(offset), "d"(whence) : "memory");
    return result;
}

static void sys_exit(long code)
{
    __asm__ volatile("int $0x80" : : "a"(0L), "D"(code) : "memory");
    for (;;);
}

static long sys_fs_size(const char* name)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(4L), "D"(name) : "memory");
    return result;
}

static long sys_fs_read(const char* name, unsigned long offset, char* buffer, unsigned long length)
{
    long result;
    __asm__ volatile("int $0x80"
                     : "=a"(result)
                     : "a"(5L), "D"(name), "S"(offset), "d"(buffer), "c"(length)
                     : "memory");
    return result;
}

static long sys_fs_write(const char* name, const char* buffer, unsigned long length)
{
    long result;
    __asm__ volatile("int $0x80"
                     : "=a"(result)
                     : "a"(6L), "D"(name), "S"(buffer), "d"(length)
                     : "memory");
    return result;
}

static void put(const char* string)
{
    unsigned long length = 0;
    while (string[length])
        length++;
    sys_write(1, string, length);
}

static int get_char(void)
{
    char c;
    if (sys_read(0, &c, 1) <= 0)
        return -1;
    return (unsigned char)c;
}

static int read_line(char* buffer, int max_length)
{
    int length = 0;
    for (;;)
    {
        char character;
        if (sys_read(0, &character, 1) <= 0)
            break;
        if (character == '\n')
            break;
        if (character == '\b')
        {
            if (length > 0)
            {
                length--;
                sys_write(1, "\b \b", 3);
            }
            continue;
        }
        if (length < max_length - 1)
        {
            buffer[length++] = character;
            sys_write(1, &character, 1);
        }
    }
    buffer[length] = 0;
    return length;
}

static void put_int(long value)
{
    char buffer[21];
    int length = 0;
    int negative = value < 0;
    unsigned long magnitude = negative ? (unsigned long)(-value) : (unsigned long)value;

    if (magnitude == 0)
        buffer[length++] = '0';

    while (magnitude > 0)
    {
        buffer[length++] = (char)('0' + magnitude % 10);
        magnitude /= 10;
    }

    if (negative)
        buffer[length++] = '-';

    for (int left = 0, right = length - 1; left < right; left++, right--)
    {
        char swap = buffer[left];
        buffer[left] = buffer[right];
        buffer[right] = swap;
    }

    sys_write(1, buffer, length);
}
