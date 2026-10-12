#include <stdio.h>
#include <stdlib.h>

int main(void)
{
    printf("primes up to N, enter N (empty line quits)\n");
    char line[32];
    for (;;)
    {
        printf("> ");
        int length = readline(line, 32);
        printf("\n");
        if (length == 0)
            break;

        long limit = atol(line);
        int count = 0;
        for (long candidate = 2; candidate <= limit; candidate++)
        {
            int prime = 1;
            for (long divisor = 2; divisor * divisor <= candidate; divisor++)
                if (candidate % divisor == 0)
                {
                    prime = 0;
                    break;
                }
            if (prime)
            {
                printf("%ld ", candidate);
                count++;
            }
        }
        printf("\n%d primes\n", count);
    }
    return 0;
}
