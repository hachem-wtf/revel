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

static long sys_brk(void* addr)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(10L), "D"(addr) : "memory");
    return result;
}

static void* sys_sbrk(long increment)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(11L), "D"(increment) : "memory");
    return (void*)result;
}

// shitty heap implementation
// temporary af this will be in its own libc
#define HEAP_HDR 16UL
#define HEAP_ALIGN 16UL
#define HEAP_MIN 32UL
#define HEAP_CHUNK (64UL * 1024UL)

static unsigned long heap_start = 0;
static unsigned long heap_end = 0;
static unsigned long heap_rover = 0;

static unsigned long heap_blk_size(unsigned long b)
{
    return *(unsigned long*)b & ~15UL;
}

static int heap_blk_used(unsigned long b)
{
    return (int)(*(unsigned long*)b & 1UL);
}

static void heap_set(unsigned long b, unsigned long size, int used)
{
    *(unsigned long*)b = size | (used ? 1UL : 0UL);
}

static unsigned long heap_align(unsigned long x)
{
    return (x + HEAP_ALIGN - 1UL) & ~(HEAP_ALIGN - 1UL);
}

// pull another hunk off sbrk and drop a free block over it
static int heap_grow(unsigned long need)
{
    unsigned long want = heap_align(need);
    if (want < HEAP_CHUNK)
        want = HEAP_CHUNK;
    unsigned long got = (unsigned long)sys_sbrk((long)want);
    if ((long)got < 0)
        return 0;
    if (heap_start == 0)
    {
        heap_start = got;
        heap_end = got;
        heap_rover = got;
    }
    heap_set(heap_end, want, 0);
    heap_end += want;
    return 1;
}

// yummy O(n) malloc implementation
static void* malloc(unsigned long len)
{
    if (len == 0)
        return 0;
    unsigned long need = heap_align(HEAP_HDR + len);
    if (need < HEAP_MIN)
        need = HEAP_MIN;

    for (;;)
    {
        if (heap_rover < heap_start || heap_rover >= heap_end)
            heap_rover = heap_start;
        unsigned long b = heap_rover;
        unsigned long limit = heap_end;
        for (int pass = 0; pass < 2; pass++)
        {
            while (b < limit)
            {
                if (!heap_blk_used(b))
                {
                    unsigned long size = heap_blk_size(b);
                    while (b + size < heap_end && !heap_blk_used(b + size))
                        size += heap_blk_size(b + size);
                    heap_set(b, size, 0);
                    if (size >= need)
                    {
                        if (size >= need + HEAP_MIN)
                        {
                            heap_set(b, need, 1);
                            heap_set(b + need, size - need, 0);
                            heap_rover = b + need;
                        }
                        else
                        {
                            heap_set(b, size, 1);
                            heap_rover = b + size;
                        }
                        if (heap_rover >= heap_end)
                            heap_rover = heap_start;
                        return (void*)(b + HEAP_HDR);
                    }
                }
                b += heap_blk_size(b);
            }
            b = heap_start;
            limit = heap_rover;
        }
        if (!heap_grow(need))
            return 0;
    }
}

static void free(void* ptr)
{
    if (ptr == 0)
        return;
    unsigned long b = (unsigned long)ptr - HEAP_HDR;
    heap_set(b, heap_blk_size(b), 0);
}

static void* calloc(unsigned long count, unsigned long size)
{
    unsigned long total = count * size;
    unsigned char* p = (unsigned char*)malloc(total);
    if (p)
        for (unsigned long i = 0; i < total; i++)
            p[i] = 0;
    return p;
}

static void* realloc(void* ptr, unsigned long len)
{
    if (ptr == 0)
        return malloc(len);
    if (len == 0)
    {
        free(ptr);
        return 0;
    }
    unsigned long b = (unsigned long)ptr - HEAP_HDR;
    unsigned long have = heap_blk_size(b) - HEAP_HDR;
    if (len <= have)
        return ptr;
    unsigned char* np = (unsigned char*)malloc(len);
    if (!np)
        return 0;
    unsigned char* src = (unsigned char*)ptr;
    for (unsigned long i = 0; i < have; i++)
        np[i] = src[i];
    free(ptr);
    return np;
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
