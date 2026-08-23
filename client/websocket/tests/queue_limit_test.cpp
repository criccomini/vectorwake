#include "../src/queue_limit.h"

#include <stdint.h>
#include <stdio.h>

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
    const uint64_t limit = 4 * 1024 * 1024;

    failed += Check(dmWebsocket::CanQueueMessage(0, limit, limit),
                    "one message may fill the queue");
    failed += Check(dmWebsocket::CanQueueMessage(limit - 1, 1, limit),
                    "the last byte fits");
    failed += Check(!dmWebsocket::CanQueueMessage(limit, 1, limit),
                    "one byte beyond the cap is refused");
    failed += Check(!dmWebsocket::CanQueueMessage(UINT64_MAX, 1, limit),
                    "an overflowing queued size is refused");

    if (failed)
        return 1;
    puts("all websocket queue limit tests pass");
    return 0;
}
