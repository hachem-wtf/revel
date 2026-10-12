#include <stdio.h>
#include <unistd.h>
#include <string.h>
#include <stdarg.h>

int putchar(int character)
{
    char byte = (char)character;
    if (write(1, &byte, 1) != 1)
        return EOF;
    return (unsigned char)byte;
}

int getchar(void)
{
    char byte;
    if (read(0, &byte, 1) <= 0)
        return EOF;
    return (unsigned char)byte;
}

int puts(const char* string)
{
    (void)write(1, string, strlen(string));
    (void)write(1, "\n", 1);
    return 0;
}

static int format_unsigned(char* buffer, unsigned long value, int base, int upper)
{
    const char* digits = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char temp[32];
    int count = 0;
    if (value == 0)
        temp[count++] = '0';
    while (value > 0)
    {
        temp[count++] = digits[value % (unsigned)base];
        value /= (unsigned)base;
    }
    for (int i = 0; i < count; i++)
        buffer[i] = temp[count - 1 - i];
    return count;
}

static int format_signed(char* buffer, long value)
{
    int negative = value < 0;
    unsigned long magnitude = negative ? (unsigned long)(-value) : (unsigned long)value;
    int count = 0;
    if (negative)
        buffer[count++] = '-';
    return count + format_unsigned(buffer + count, magnitude, 10, 0);
}

#define PRINTF_BUFFER 256

// yoinked straight off open source
int printf(const char* format, ...)
{
    char out[PRINTF_BUFFER];
    int filled = 0;
    int total = 0;
    va_list args;
    va_start(args, format);

#define FLUSH()                          \
    do {                                 \
        if (filled > 0)                  \
        {                                \
            (void)write(1, out, filled); \
            filled = 0;                  \
        }                                \
    } while (0)
#define EMIT(ch)                      \
    do {                              \
        if (filled == PRINTF_BUFFER)  \
            FLUSH();                  \
        out[filled++] = (char)(ch);   \
        total++;                      \
    } while (0)

    for (const char* cursor = format; *cursor; cursor++)
    {
        if (*cursor != '%')
        {
            EMIT(*cursor);
            continue;
        }

        cursor++;
        if (*cursor == '%')
        {
            EMIT('%');
            continue;
        }

        int zero_pad = 0;
        if (*cursor == '0')
        {
            zero_pad = 1;
            cursor++;
        }
        int width = 0;
        while (*cursor >= '0' && *cursor <= '9')
        {
            width = width * 10 + (*cursor - '0');
            cursor++;
        }
        int is_long = 0;
        while (*cursor == 'l')
        {
            is_long = 1;
            cursor++;
        }

        char conversion = *cursor;
        if (conversion == 's')
        {
            const char* string = va_arg(args, const char*);
            if (!string)
                string = "(null)";
            int length = (int)strlen(string);
            for (int i = length; i < width; i++)
                EMIT(' ');
            for (int i = 0; i < length; i++)
                EMIT(string[i]);
            continue;
        }
        if (conversion == 'c')
        {
            int character = va_arg(args, int);
            for (int i = 1; i < width; i++)
                EMIT(' ');
            EMIT(character);
            continue;
        }

        char number[34];
        int length = 0;
        if (conversion == 'd' || conversion == 'i')
        {
            long value = is_long ? va_arg(args, long) : (long)va_arg(args, int);
            length = format_signed(number, value);
        }
        else if (conversion == 'u')
        {
            unsigned long value = is_long ? va_arg(args, unsigned long) : (unsigned long)va_arg(args, unsigned int);
            length = format_unsigned(number, value, 10, 0);
        }
        else if (conversion == 'x' || conversion == 'X')
        {
            unsigned long value = is_long ? va_arg(args, unsigned long) : (unsigned long)va_arg(args, unsigned int);
            length = format_unsigned(number, value, 16, conversion == 'X');
        }
        else if (conversion == 'p')
        {
            unsigned long value = (unsigned long)va_arg(args, void*);
            EMIT('0');
            EMIT('x');
            length = format_unsigned(number, value, 16, 0);
        }
        else
        {
            EMIT('%');
            EMIT(conversion);
            continue;
        }

        for (int i = length; i < width; i++)
            EMIT(zero_pad ? '0' : ' ');
        for (int i = 0; i < length; i++)
            EMIT(number[i]);
    }

    FLUSH();
    va_end(args);
    return total;

#undef EMIT
#undef FLUSH
}

int readline(char* buffer, int max_length)
{
    int length = 0;
    for (;;)
    {
        char character;
        if (read(0, &character, 1) <= 0)
            break;
        if (character == '\n')
            break;
        if (character == '\b')
        {
            if (length > 0)
            {
                length--;
                (void)write(1, "\b \b", 3);
            }
            continue;
        }
        if (length < max_length - 1)
        {
            buffer[length++] = character;
            (void)write(1, &character, 1);
        }
    }
    buffer[length] = 0;
    return length;
}
