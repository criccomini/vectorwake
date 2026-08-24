#include <dmsdk/dlib/socket.h>
#include <dmsdk/dlib/sslsocket.h>
#include "websocket.h"
#include "socket_send.h"

namespace dmWebsocket
{

dmSocket::Result WaitForSocket(WebsocketConnection* conn, dmSocket::SelectorKind kind, int timeout)
{
    dmSocket::Selector selector;
    dmSocket::SelectorZero(&selector);
    dmSocket::SelectorSet(&selector, kind, conn->m_Socket);
    return dmSocket::Select(&selector, timeout);
}

struct ConnectionSocketOps
{
    typedef dmSocket::Result Result;
    WebsocketConnection* m_Connection;

    explicit ConnectionSocketOps(WebsocketConnection* connection)
    : m_Connection(connection)
    {
    }

    Result SendSome(const char* data, int size, int* sent_bytes)
    {
        Result result;
        WebsocketConnection* conn = m_Connection;
        if (conn->m_SSLSocket)
            result = dmSSLSocket::Send(
                conn->m_SSLSocket, data, size, sent_bytes);
        else
            result = dmSocket::Send(conn->m_Socket, data, size, sent_bytes);
        return result;
    }

    Result Ok() const
    {
        return dmSocket::RESULT_OK;
    }

    Result WouldBlock() const
    {
        return dmSocket::RESULT_WOULDBLOCK;
    }

    bool IsBlocked(Result result) const
    {
        return result == dmSocket::RESULT_WOULDBLOCK ||
               result == dmSocket::RESULT_TRY_AGAIN;
    }

    bool DeadlineExpired() const
    {
        return dmTime::GetMonotonicTime() >=
               m_Connection->m_ConnectTimeout;
    }

    Result WaitWritable()
    {
        return WaitForSocket(m_Connection, dmSocket::SELECTOR_KIND_WRITE,
                             SOCKET_WAIT_TIMEOUT);
    }

    void Yield()
    {
        // TLS may report writable while its next send still needs another
        // socket event. Yield before trying again in that case.
        dmTime::Sleep(1000);
    }

    void Trace(const char* data, int size)
    {
        DebugPrint(2, "Sent buffer:", data, size);
    }
};

dmSocket::Result Send(WebsocketConnection* conn, const char* buffer, int length, int* out_sent_bytes)
{
    ConnectionSocketOps socket(conn);

    return SendBuffer(socket, buffer, length, out_sent_bytes);
}

dmSocket::Result Receive(WebsocketConnection* conn, void* buffer, int length, int* received_bytes)
{
    dmSocket::Result sr;
    if (conn->m_SSLSocket)
        sr = dmSSLSocket::Receive(conn->m_SSLSocket, buffer, length, received_bytes);
    else
        sr = dmSocket::Receive(conn->m_Socket, buffer, length, received_bytes);

    int num_bytes = received_bytes ? (uint32_t)*received_bytes : 0;
    if (sr == dmSocket::RESULT_OK && num_bytes > 0)
        DebugPrint(2, "Received bytes:", buffer, num_bytes);

    return sr;
}

} // namespace
