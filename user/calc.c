#include <stdio.h>

static int is_digit(char character)
{
    return character >= '0' && character <= '9';
}

int main(void)
{
    printf("calc, e.g. 3 + 4 * 2 (left to right), empty line quits\n");

    char line[128];
    for (;;)
    {
        printf("> ");
        int length = readline(line, 128);
        printf("\n");
        if (length == 0)
            break;

        long accumulator = 0;
        char operator = '+';
        int valid = 1;
        int saw_number = 0;
        int position = 0;

        while (position < length)
        {
            char character = line[position];
            if (character == ' ')
            {
                position++;
                continue;
            }

            if (is_digit(character))
            {
                long value = 0;
                while (position < length && is_digit(line[position]))
                    value = value * 10 + (line[position++] - '0');

                if (operator == '+')
                    accumulator += value;
                else if (operator == '-')
                    accumulator -= value;
                else if (operator == '*')
                    accumulator *= value;
                else if (operator == '/' || operator == '%')
                {
                    if (value == 0)
                    {
                        printf("divide by zero\n");
                        valid = 0;
                        break;
                    }
                    accumulator = (operator == '/') ? accumulator / value : accumulator % value;
                }

                saw_number = 1;
            }
            else if (character == '+' || character == '-' || character == '*'
                     || character == '/' || character == '%')
            {
                operator = character;
                position++;
            }
            else
            {
                printf("bad character\n");
                valid = 0;
                break;
            }
        }

        if (valid && saw_number)
            printf("= %ld\n", accumulator);
    }

    return 0;
}
