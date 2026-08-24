#ifndef VW_WEBSOCKET_SOCKET_SEND_H
#define VW_WEBSOCKET_SOCKET_SEND_H

namespace dmWebsocket
{

template <typename SocketOps>
static inline typename SocketOps::Result SendBuffer(
    SocketOps& socket, const char* buffer, int length, int* out_sent_bytes)
{
    typedef typename SocketOps::Result Result;

    int total_sent_bytes = 0;
    int sent_bytes = 0;

    while (total_sent_bytes < length)
    {
        Result result = socket.SendSome(
            buffer + total_sent_bytes, length - total_sent_bytes, &sent_bytes);

        if (result == socket.Ok() && sent_bytes == 0)
            result = socket.WouldBlock();

        if (socket.IsBlocked(result))
        {
            // A framed write can resume from a partial result. A handshake
            // cannot, so it waits for readiness until its deadline expires.
            if (out_sent_bytes)
            {
                *out_sent_bytes = total_sent_bytes;
                if (total_sent_bytes > 0)
                {
                    socket.Trace(buffer, total_sent_bytes);
                    return socket.Ok();
                }
                return result;
            }

            if (socket.DeadlineExpired())
                return result;

            Result wait_result = socket.WaitWritable();
            if (wait_result != socket.Ok() && !socket.IsBlocked(wait_result))
                return wait_result;

            socket.Yield();
            continue;
        }

        if (result != socket.Ok())
            return result;

        total_sent_bytes += sent_bytes;
    }

    if (out_sent_bytes)
        *out_sent_bytes = total_sent_bytes;

    socket.Trace(buffer, total_sent_bytes);
    return socket.Ok();
}

} // namespace dmWebsocket

#endif
