#include <string.h>

size_t strlen(const char* string)
{
    size_t length = 0;
    while (string[length])
        length++;
    return length;
}

int strcmp(const char* a, const char* b)
{
    while (*a && *a == *b)
    {
        a++;
        b++;
    }

    return (int)(unsigned char)*a - (int)(unsigned char)*b;
}

int strncmp(const char* a, const char* b, size_t length)
{
    for (size_t i = 0; i < length; i++)
    {
        unsigned char ca = (unsigned char)a[i];
        unsigned char cb = (unsigned char)b[i];
        if (ca != cb)
            return (int)ca - (int)cb;
        if (ca == 0)
            return 0;
    }
    return 0;
}

char* strcpy(char* destination, const char* source)
{
    char* out = destination;
    while ((*out++ = *source++))
        ;
    return destination;
}

char* strncpy(char* destination, const char* source, size_t length)
{
    size_t i = 0;
    for (; i < length && source[i]; i++)
        destination[i] = source[i];
    for (; i < length; i++)
        destination[i] = 0;
    return destination;
}

void* memcpy(void* destination, const void* source, size_t length)
{
    unsigned char* out = destination;
    const unsigned char* in = source;
    for (size_t i = 0; i < length; i++)
        out[i] = in[i];
    return destination;
}

void* memmove(void* destination, const void* source, size_t length)
{
    unsigned char* out = destination;
    const unsigned char* in = source;
    if (out < in)
        for (size_t i = 0; i < length; i++)
            out[i] = in[i];
    else
        for (size_t i = length; i > 0; i--)
            out[i - 1] = in[i - 1];
    return destination;
}

void* memset(void* destination, int value, size_t length)
{
    unsigned char* out = destination;
    for (size_t i = 0; i < length; i++)
        out[i] = (unsigned char)value;
    return destination;
}

int memcmp(const void* a, const void* b, size_t length)
{
    const unsigned char* aa = a;
    const unsigned char* bb = b;
    for (size_t i = 0; i < length; i++)
        if (aa[i] != bb[i])
            return (int)aa[i] - (int)bb[i];
    return 0;
}
