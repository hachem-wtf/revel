#define SEEK_SET 0
#define SEEK_CUR 1
#define SEEK_END 2

#define O_WRONLY 1
#define O_CREAT  0x40
#define O_TRUNC  0x200
#define O_APPEND 0x400

static inline __attribute__((warn_unused_result)) long sys_write(long fd, const char* buffer, unsigned long length)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(1L), "D"(fd), "S"(buffer), "d"(length) : "memory");
    return result;
}

static inline __attribute__((warn_unused_result)) long sys_read(long fd, char* buffer, unsigned long length)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(2L), "D"(fd), "S"(buffer), "d"(length) : "memory");
    return result;
}

static inline __attribute__((warn_unused_result)) long sys_open(const char* path, long flags)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(7L), "D"(path), "S"(flags) : "memory");
    return result;
}

static inline __attribute__((warn_unused_result)) long sys_close(long fd)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(8L), "D"(fd) : "memory");
    return result;
}

static inline __attribute__((warn_unused_result)) long sys_lseek(long fd, long offset, long whence)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(9L), "D"(fd), "S"(offset), "d"(whence) : "memory");
    return result;
}

static inline void sys_exit(long code)
{
    __asm__ volatile("int $0x80" : : "a"(0L), "D"(code) : "memory");
    for (;;);
}

static inline __attribute__((warn_unused_result)) long sys_fs_size(const char* name)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(4L), "D"(name) : "memory");
    return result;
}

static inline __attribute__((warn_unused_result)) long sys_fs_read(const char* name, unsigned long offset, char* buffer, unsigned long length)
{
    long result;
    __asm__ volatile("int $0x80"
                     : "=a"(result)
                     : "a"(5L), "D"(name), "S"(offset), "d"(buffer), "c"(length)
                     : "memory");
    return result;
}

static inline __attribute__((warn_unused_result)) long sys_fs_write(const char* name, const char* buffer, unsigned long length)
{
    long result;
    __asm__ volatile("int $0x80"
                     : "=a"(result)
                     : "a"(6L), "D"(name), "S"(buffer), "d"(length)
                     : "memory");
    return result;
}

static inline __attribute__((warn_unused_result)) long sys_brk(void* address)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(10L), "D"(address) : "memory");
    return result;
}

static inline __attribute__((warn_unused_result)) void* sys_sbrk(long increment)
{
    long result;
    __asm__ volatile("int $0x80" : "=a"(result) : "a"(11L), "D"(increment) : "memory");
    return (void*)result;
}

// shitty heap implementation
// temporary af this will be in its own libc
#define HEAP_HEADER 16UL
#define HEAP_ALIGN 16UL
#define HEAP_MIN 32UL
#define HEAP_CHUNK (64UL * 1024UL)

static unsigned long heap_start = 0;
static unsigned long heap_end = 0;
static unsigned long heap_rover = 0;

static inline __attribute__((warn_unused_result)) unsigned long heap_block_size(unsigned long block)
{
    return *(unsigned long*)block & ~15UL;
}

static inline __attribute__((warn_unused_result)) int heap_block_used(unsigned long block)
{
    return (int)(*(unsigned long*)block & 1UL);
}

static inline void heap_set(unsigned long block, unsigned long size, int used)
{
    *(unsigned long*)block = size | (used ? 1UL : 0UL);
}

static inline __attribute__((warn_unused_result)) unsigned long heap_align(unsigned long value)
{
    return (value + HEAP_ALIGN - 1UL) & ~(HEAP_ALIGN - 1UL);
}

// pull another hunk off sbrk and drop a free block over it
static inline __attribute__((warn_unused_result)) int heap_grow(unsigned long need)
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
static inline __attribute__((warn_unused_result)) void* malloc(unsigned long length)
{
    if (length == 0)
        return 0;
    unsigned long need = heap_align(HEAP_HEADER + length);
    if (need < HEAP_MIN)
        need = HEAP_MIN;

    for (;;)
    {
        if (heap_rover < heap_start || heap_rover >= heap_end)
            heap_rover = heap_start;
        unsigned long block = heap_rover;
        unsigned long limit = heap_end;
        for (int pass = 0; pass < 2; pass++)
        {
            while (block < limit)
            {
                if (!heap_block_used(block))
                {
                    unsigned long size = heap_block_size(block);
                    while (block + size < heap_end && !heap_block_used(block + size))
                        size += heap_block_size(block + size);
                    heap_set(block, size, 0);
                    if (size >= need)
                    {
                        if (size >= need + HEAP_MIN)
                        {
                            heap_set(block, need, 1);
                            heap_set(block + need, size - need, 0);
                            heap_rover = block + need;
                        }
                        else
                        {
                            heap_set(block, size, 1);
                            heap_rover = block + size;
                        }
                        if (heap_rover >= heap_end)
                            heap_rover = heap_start;
                        return (void*)(block + HEAP_HEADER);
                    }
                }
                block += heap_block_size(block);
            }
            block = heap_start;
            limit = heap_rover;
        }
        if (!heap_grow(need))
            return 0;
    }
}

static inline void free(void* pointer)
{
    if (pointer == 0)
        return;
    unsigned long block = (unsigned long)pointer - HEAP_HEADER;
    heap_set(block, heap_block_size(block), 0);
}

static inline __attribute__((warn_unused_result)) void* calloc(unsigned long count, unsigned long size)
{
    unsigned long total = count * size;
    unsigned char* bytes = (unsigned char*)malloc(total);
    if (bytes)
        for (unsigned long i = 0; i < total; i++)
            bytes[i] = 0;
    return bytes;
}

static inline __attribute__((warn_unused_result)) void* realloc(void* pointer, unsigned long length)
{
    if (pointer == 0)
        return malloc(length);
    if (length == 0)
    {
        free(pointer);
        return 0;
    }
    unsigned long block = (unsigned long)pointer - HEAP_HEADER;
    unsigned long have = heap_block_size(block) - HEAP_HEADER;
    if (length <= have)
        return pointer;
    unsigned char* new_block = (unsigned char*)malloc(length);
    if (!new_block)
        return 0;
    unsigned char* source = (unsigned char*)pointer;
    for (unsigned long i = 0; i < have; i++)
        new_block[i] = source[i];
    free(pointer);
    return new_block;
}

static inline void put(const char* string)
{
    unsigned long length = 0;
    while (string[length])
        length++;
    (void)sys_write(1, string, length);
}

static inline __attribute__((warn_unused_result)) int get_char(void)
{
    char character;
    if (sys_read(0, &character, 1) <= 0)
        return -1;
    return (unsigned char)character;
}

static inline __attribute__((warn_unused_result)) int read_line(char* buffer, int max_length)
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
                (void)sys_write(1, "\b \b", 3);
            }
            continue;
        }
        if (length < max_length - 1)
        {
            buffer[length++] = character;
            (void)sys_write(1, &character, 1);
        }
    }
    buffer[length] = 0;
    return length;
}

static inline void put_int(long value)
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

    (void)sys_write(1, buffer, length);
}
