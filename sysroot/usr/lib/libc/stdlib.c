#include <stdlib.h>
#include <unistd.h>
#include <sys/syscall.h>

#define HEAP_HEADER 16UL
#define HEAP_ALIGN 16UL
#define HEAP_MIN 32UL
#define HEAP_CHUNK (64UL * 1024UL)

static unsigned long heap_start = 0;
static unsigned long heap_end = 0;
static unsigned long heap_rover = 0;

static unsigned long heap_block_size(unsigned long block)
{
    return *(unsigned long*)block & ~15UL;
}

static int heap_block_used(unsigned long block)
{
    return (int)(*(unsigned long*)block & 1UL);
}

static void heap_set(unsigned long block, unsigned long size, int used)
{
    *(unsigned long*)block = size | (used ? 1UL : 0UL);
}

static unsigned long heap_align(unsigned long value)
{
    return (value + HEAP_ALIGN - 1UL) & ~(HEAP_ALIGN - 1UL);
}

// pull another hunk off sbrk and drop a free block over it
static int heap_grow(unsigned long need)
{
    unsigned long want = heap_align(need);
    if (want < HEAP_CHUNK)
        want = HEAP_CHUNK;
    unsigned long got = (unsigned long)sbrk((long)want);
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

// fire O(n) malloc implementation frfr
void* malloc(size_t length)
{
    if (length == 0)
        return NULL;
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
                    // lazily coalesce the free run starting here
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
            return NULL;
    }
}

void free(void* pointer)
{
    if (pointer == NULL)
        return;
    unsigned long block = (unsigned long)pointer - HEAP_HEADER;
    heap_set(block, heap_block_size(block), 0);
}

void* calloc(size_t count, size_t size)
{
    unsigned long total = (unsigned long)count * (unsigned long)size;
    unsigned char* bytes = malloc(total);
    if (bytes)
        for (unsigned long i = 0; i < total; i++)
            bytes[i] = 0;
    return bytes;
}

void* realloc(void* pointer, size_t length)
{
    if (pointer == NULL)
        return malloc(length);
    if (length == 0)
    {
        free(pointer);
        return NULL;
    }
    unsigned long block = (unsigned long)pointer - HEAP_HEADER;
    unsigned long have = heap_block_size(block) - HEAP_HEADER;
    if (length <= have)
        return pointer;
    unsigned char* grown = malloc(length);
    if (!grown)
        return NULL;
    unsigned char* source = pointer;
    for (unsigned long i = 0; i < have; i++)
        grown[i] = source[i];
    free(pointer);
    return grown;
}

void exit(int code)
{
    __syscall1(SYS_exit, code);
    for (;;)
        ;
}

long atol(const char* string)
{
    while (*string == ' ' || *string == '\t')
        string++;
    int negative = 0;
    if (*string == '-')
    {
        negative = 1;
        string++;
    }
    else if (*string == '+')
        string++;
    long value = 0;
    while (*string >= '0' && *string <= '9')
    {
        value = value * 10 + (*string - '0');
        string++;
    }
    return negative ? -value : value;
}

int atoi(const char* string)
{
    return (int)atol(string);
}

int abs(int value)
{
    return value < 0 ? -value : value;
}
