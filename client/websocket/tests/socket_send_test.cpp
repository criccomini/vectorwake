#include "../src/socket_send.h"

#include <stdio.h>

enum Result
{
    RESULT_OK,
    RESULT_WOULDBLOCK,
    RESULT_TRY_AGAIN,
    RESULT_ERROR,
};

struct Step
{
    Result m_Result;
    int m_Bytes;
};

struct SocketOps
{
    typedef ::Result Result;

    const Step* m_Steps;
    int m_StepCount;
    int m_SendCalls;
    int m_Waits;
    int m_Yields;
    int m_TracedBytes;
    bool m_Expired;
    Result m_WaitResult;

    Result SendSome(const char*, int, int* sent_bytes)
    {
        if (m_SendCalls >= m_StepCount)
            return RESULT_ERROR;
        const Step& step = m_Steps[m_SendCalls++];
        *sent_bytes = step.m_Bytes;
        return step.m_Result;
    }

    Result Ok() const
    {
        return RESULT_OK;
    }

    Result WouldBlock() const
    {
        return RESULT_WOULDBLOCK;
    }

    bool IsBlocked(Result result) const
    {
        return result == RESULT_WOULDBLOCK || result == RESULT_TRY_AGAIN;
    }

    bool DeadlineExpired() const
    {
        return m_Expired;
    }

    Result WaitWritable()
    {
        ++m_Waits;
        return m_WaitResult;
    }

    void Yield()
    {
        ++m_Yields;
    }

    void Trace(const char*, int size)
    {
        m_TracedBytes = size;
    }
};

static SocketOps MakeSocket(const Step* steps, int count)
{
    SocketOps socket = {
        steps, count, 0, 0, 0, -1, false, RESULT_OK,
    };
    return socket;
}

static int Check(bool condition, const char* message)
{
    if (condition)
        return 0;
    fprintf(stderr, "FAIL %s\n", message);
    return 1;
}

static int HandshakeWaitsForWritableSocket()
{
    const Step steps[] = {
        {RESULT_WOULDBLOCK, 0},
        {RESULT_OK, 5},
    };
    SocketOps socket = MakeSocket(steps, 2);

    Result result = dmWebsocket::SendBuffer(socket, "hello", 5, 0);

    int failed = 0;
    failed += Check(result == RESULT_OK, "handshake send failed");
    failed += Check(socket.m_SendCalls == 2,
                    "handshake did not retry after readiness");
    failed += Check(socket.m_Waits == 1,
                    "handshake retried without waiting for readiness");
    failed += Check(socket.m_Yields == 1,
                    "handshake retry did not yield");
    failed += Check(socket.m_TracedBytes == 5,
                    "handshake did not send the whole buffer");
    return failed;
}

static int FramedSendReturnsPartialProgress()
{
    const Step steps[] = {
        {RESULT_OK, 3},
        {RESULT_WOULDBLOCK, 0},
        {RESULT_OK, 2},
    };
    SocketOps socket = MakeSocket(steps, 3);
    int sent_bytes = -1;

    Result result = dmWebsocket::SendBuffer(
        socket, "hello", 5, &sent_bytes);

    int failed = 0;
    failed += Check(result == RESULT_OK,
                    "partial framed write was reported as an error");
    failed += Check(sent_bytes == 3,
                    "partial framed write lost its byte count");
    failed += Check(socket.m_SendCalls == 2,
                    "partial framed write kept sending after backpressure");
    failed += Check(socket.m_Waits == 0 && socket.m_Yields == 0,
                    "partial framed write waited instead of returning");
    failed += Check(socket.m_TracedBytes == 3,
                    "partial framed write traced the wrong byte count");
    return failed;
}

static int FramedSendReturnsImmediateBackpressure()
{
    const Step steps[] = {
        {RESULT_TRY_AGAIN, 0},
        {RESULT_OK, 5},
    };
    SocketOps socket = MakeSocket(steps, 2);
    int sent_bytes = -1;

    Result result = dmWebsocket::SendBuffer(
        socket, "hello", 5, &sent_bytes);

    int failed = 0;
    failed += Check(result == RESULT_TRY_AGAIN,
                    "immediate backpressure was hidden");
    failed += Check(sent_bytes == 0,
                    "immediate backpressure reported bytes sent");
    failed += Check(socket.m_SendCalls == 1,
                    "framed write hot-looped on immediate backpressure");
    failed += Check(socket.m_Waits == 0 && socket.m_Yields == 0,
                    "framed write waited on immediate backpressure");
    return failed;
}

int main()
{
    int failed = 0;
    failed += HandshakeWaitsForWritableSocket();
    failed += FramedSendReturnsPartialProgress();
    failed += FramedSendReturnsImmediateBackpressure();

    if (failed)
        return 1;
    puts("all websocket send behavior tests pass");
    return 0;
}
