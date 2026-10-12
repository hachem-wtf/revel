#include <stdio.h>
#include <stdlib.h>
#include <unistd.h>

static void check(const char* name, int ok)
{
    printf("%s%s\n", ok ? "ok   " : "FAIL ", name);
}

int main(void)
{
    long start = (long)sbrk(0);
    printf("heap base: %ld\n", start);

    // obese alloc test
    char* run[80];
    for (int i = 0; i < 80; i++)
        run[i] = malloc(4000);
    long run_after = (long)sbrk(0);
    for (int i = 0; i < 80; i++)
        free(run[i]);
    char* merged = malloc(80 * 4000 - 8000);
    long merge_after = (long)sbrk(0);
    check("freed neighbours coalesce", merged != 0 && merge_after <= run_after);
    free(merged);

    // a pile of small tagged allocations
    char* blocks[16];
    for (int i = 0; i < 16; i++)
    {
        blocks[i] = malloc(64);
        for (int j = 0; j < 64; j++)
            blocks[i][j] = (char)(i * 7 + j);
    }
    int small_ok = 1;
    for (int i = 0; i < 16; i++)
        for (int j = 0; j < 64; j++)
            if (blocks[i][j] != (char)(i * 7 + j))
                small_ok = 0;
    check("small allocs keep their data", small_ok);

    // a big block spanning several pages written edge to edge
    unsigned long big = 20000;
    unsigned char* buffer = malloc(big);
    for (unsigned long k = 0; k < big; k++)
        buffer[k] = (unsigned char)(k & 0xff);
    int big_ok = 1;
    for (unsigned long k = 0; k < big; k++)
        if (buffer[k] != (unsigned char)(k & 0xff))
            big_ok = 0;
    check("big multi page alloc", big_ok);

    // testing that the heap doesnt grow across the loop
    long churn_before = (long)sbrk(0);
    for (int i = 0; i < 2000; i++)
    {
        void* pointer = malloc(500);
        free(pointer);
    }
    long churn_after = (long)sbrk(0);
    check("alloc/free churn reclaims (no growth)", churn_before == churn_after);

    // calloc dirty test
    unsigned char* zeroed = calloc(200, 1);
    int zero_ok = 1;
    for (int i = 0; i < 200; i++)
        if (zeroed[i] != 0)
            zero_ok = 0;
    check("calloc is zeroed", zero_ok);

    // realloc test
    char* grown = malloc(32);
    for (int i = 0; i < 32; i++)
        grown[i] = (char)(i + 1);
    grown = realloc(grown, 500);
    int grow_ok = 1;
    for (int i = 0; i < 32; i++)
        if (grown[i] != (char)(i + 1))
            grow_ok = 0;
    check("realloc grows and preserves data", grow_ok);

    long end = (long)sbrk(0);
    printf("heap high water: %ld bytes\n", end - start);

    return 0;
}
