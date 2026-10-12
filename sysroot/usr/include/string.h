#ifndef _STRING_H
#define _STRING_H

#include <stddef.h>

size_t strlen(const char* string);
int strcmp(const char* a, const char* b);
int strncmp(const char* a, const char* b, size_t length);
char* strcpy(char* destination, const char* source);
char* strncpy(char* destination, const char* source, size_t length);

void* memcpy(void* destination, const void* source, size_t length);
void* memmove(void* destination, const void* source, size_t length);
void* memset(void* destination, int value, size_t length);
int   memcmp(const void* a, const void* b, size_t length);

#endif
