#include "../src/connection_publish.h"

#include <stdio.h>

struct Connection
{
};

struct Connections
{
    Connection* m_Entries[2];
    int m_Size;
    int m_Capacity;
    int m_Growth;

    bool Full() const
    {
        return m_Size == m_Capacity;
    }

    void OffsetCapacity(int amount)
    {
        m_Capacity += amount;
        m_Growth += amount;
    }

    void Push(Connection* connection)
    {
        m_Entries[m_Size++] = connection;
    }

    bool Contains(Connection* connection) const
    {
        for (int i = 0; i < m_Size; ++i)
        {
            if (m_Entries[i] == connection)
                return true;
        }
        return false;
    }
};

static Connections* g_Connections;
static bool g_Started;
static bool g_PublishedWhenStarted;

static void Start(Connection* connection)
{
    g_Started = true;
    g_PublishedWhenStarted = g_Connections->Contains(connection);
}

int main()
{
    Connections connections = {{0, 0}, 0, 0, 0};
    Connection connection;
    g_Connections = &connections;

    dmWebsocket::PublishConnectionAndStart(
        connections, &connection, Start);

    if (!g_Started || !g_PublishedWhenStarted)
    {
        fputs("FAIL worker started before connection publication\n", stderr);
        return 1;
    }
    if (connections.m_Size != 1 || connections.m_Growth != 2)
    {
        fputs("FAIL connection publication did not grow the registry\n", stderr);
        return 1;
    }

    puts("all websocket connection publication tests pass");
    return 0;
}
