#include "../src/status_format.h"

#include <stdio.h>
#include <string.h>

static int Render(char* buffer, size_t capacity, const char* format, ...)
{
    va_list args;
    va_start(args, format);
    int stored = dmWebsocket::FormatStatus(buffer, capacity, format, args);
    va_end(args);
    return stored;
}

static int Check(bool condition, const char* message)
{
    if (condition)
        return 0;
    fprintf(stderr, "FAIL %s\n", message);
    return 1;
}

int main()
{
    int failed = 0;

    char response[64] = "HTTP/1.1 200 OK";
    const char* complete = "bad handshake: HTTP/1.1 200 OK";
    int stored = Render(response, sizeof response, "bad handshake: %s", response);
    failed += Check(strcmp(response, complete) == 0,
                    "an overlapping source remains intact while formatting");
    failed += Check(stored == (int)strlen(complete),
                    "the complete message reports its stored length");

    char short_buffer[8] = "payload";
    stored = Render(short_buffer, sizeof short_buffer, "error: %s", short_buffer);
    failed += Check(strcmp(short_buffer, "error: ") == 0,
                    "a long message is terminated at the buffer boundary");
    failed += Check(stored == (int)sizeof short_buffer - 1,
                    "a truncated message reports only stored bytes");

    char untouched = 'x';
    stored = Render(&untouched, 0, "ignored");
    failed += Check(stored == 0 && untouched == 'x',
                    "a zero-sized buffer is left alone");

    if (failed)
        return 1;
    puts("all websocket status formatting tests pass");
    return 0;
}
