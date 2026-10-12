#ifndef _STDLIB_H
#define _STDLIB_H

#include <stddef.h>

void* malloc(size_t length);
void  free(void* pointer);
void* calloc(size_t count, size_t size);
void* realloc(void* pointer, size_t length);

void exit(int code) __attribute__((noreturn));

int  atoi(const char* string);
long atol(const char* string);
int  abs(int value);

#endif
