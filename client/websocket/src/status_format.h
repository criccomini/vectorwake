#ifndef VW_WEBSOCKET_STATUS_FORMAT_H
#define VW_WEBSOCKET_STATUS_FORMAT_H

#include <stdarg.h>
#include <stddef.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

namespace dmWebsocket
{

static inline int FormatStatus(char* buffer, size_t capacity, const char* format, va_list args)
{
    if (!buffer || capacity == 0)
        return 0;

    // The format arguments may point into buffer. Writing into scratch storage
    // keeps those arguments intact until vsnprintf has finished reading them.
    char* message = (char*)malloc(capacity);
    if (!message)
    {
        buffer[0] = 0;
        return 0;
    }

    va_list copy;
    va_copy(copy, args);
    int wanted = vsnprintf(message, capacity, format, copy);
    va_end(copy);

    int stored = 0;
    if (wanted >= 0)
    {
        size_t available = capacity - 1;
        size_t actual = (size_t)wanted < available ? (size_t)wanted : available;
        memcpy(buffer, message, actual);
        buffer[actual] = 0;
        stored = (int)actual;
    }
    else
    {
        buffer[0] = 0;
    }

    free(message);
    return stored;
}

} // namespace dmWebsocket

#endif
