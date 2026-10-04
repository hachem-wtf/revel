#include "user.h"

void _start(void)
{
    put("primes up to N, enter N (empty line quits)\n");
    char line[32];
    for (;;)
    {
        put("> ");
        int length = read_line(line, 32);
        put("\n");
        if (length == 0)
            break;

        long limit = 0;
        for (int position = 0; position < length; position++)
            if (line[position] >= '0' && line[position] <= '9')
                limit = limit * 10 + (line[position] - '0');

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
                put_int(candidate);
                put(" ");
                count++;
            }
        }
        put("\n");
        put_int(count);
        put(" primes\n");
    }
    sys_exit(0);
}
