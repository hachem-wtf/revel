#ifndef _STDIO_H
#define _STDIO_H

#define EOF (-1)

int putchar(int character);
int getchar(void);
int puts(const char* string);
int printf(const char* format, ...);

// revel only, not part of stdc
// read a line from stdin -> returns length
int readline(char* buffer, int max_length);

#endif
