#ifndef VW_WEBSOCKET_CONNECTION_PUBLISH_H
#define VW_WEBSOCKET_CONNECTION_PUBLISH_H

namespace dmWebsocket
{

template <typename Connections, typename Connection, typename Start>
static inline void PublishConnectionAndStart(
    Connections& connections, Connection* connection, Start start)
{
    if (connections.Full())
        connections.OffsetCapacity(2);
    connections.Push(connection);
    start(connection);
}

} // namespace dmWebsocket

#endif
