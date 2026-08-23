#ifndef VW_WEBSOCKET_QUEUE_LIMIT_H
#define VW_WEBSOCKET_QUEUE_LIMIT_H

#include <stdint.h>

namespace dmWebsocket
{

static inline bool CanQueueMessage(uint64_t queued, uint64_t incoming, uint64_t limit)
{
    return queued <= limit && incoming <= limit - queued;
}

} // namespace dmWebsocket

#endif
