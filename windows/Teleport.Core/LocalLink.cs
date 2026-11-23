using System.Buffers.Binary;
using System.Net;
using System.Net.NetworkInformation;
using System.Net.Sockets;
using System.Threading.Channels;

namespace Teleport.Core;

/// Direct file sessions on the same network (SPEC.md "Direct connections"): plain TCP
/// carrying what the relay would, framed as u32 BE length ‖ payload. The session's own
/// handshake and encryption are unchanged.
public static class LocalLink
{
    public const int MaxFrame = 4 * 1024 * 1024;

    /// This PC's private IPv4 addresses on up interfaces (home networks).
    /// Private IPv4 addresses, the real network first: Wi-Fi and Ethernet adapters with a
    /// gateway, then the rest (VPN adapters such as NordVPN also hand out 10.x addresses that
    /// a phone on the same router can never reach, and each costs it a connect timeout).
    public static List<string> Addresses() =>
    [
        .. NetworkInterface.GetAllNetworkInterfaces()
            .Where(n => n.OperationalStatus == OperationalStatus.Up && n.NetworkInterfaceType != NetworkInterfaceType.Loopback)
            .OrderBy(Rank)
            .SelectMany(n => n.GetIPProperties().UnicastAddresses)
            .Select(a => a.Address)
            .Where(a => a.AddressFamily == AddressFamily.InterNetwork && IsPrivate(a))
            .Select(a => a.ToString())
            .Distinct(),
    ];

    private static int Rank(NetworkInterface n)
    {
        var physical = n.NetworkInterfaceType is NetworkInterfaceType.Wireless80211 or NetworkInterfaceType.Ethernet or NetworkInterfaceType.GigabitEthernet;
        var gateway = n.GetIPProperties().GatewayAddresses.Any(g => g.Address.AddressFamily == AddressFamily.InterNetwork && !g.Address.Equals(IPAddress.Any));
        return (physical && gateway) ? 0 : gateway ? 1 : 2;
    }

    public static bool IsPrivate(IPAddress ip)
    {
        var b = ip.GetAddressBytes();
        return b[0] == 10 || (b[0] == 172 && b[1] is >= 16 and <= 31) || (b[0] == 192 && b[1] == 168);
    }
}

/// A session pipe over one accepted TCP connection.
public sealed class TcpPipe : ISessionPipe
{
    private readonly TcpClient _client;
    private readonly NetworkStream _stream;
    private readonly Channel<byte[]> _incoming = Channel.CreateUnbounded<byte[]>();
    private readonly Channel<byte[]> _outgoing = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
    private int _closed;

    public TcpPipe(TcpClient client)
    {
        _client = client;
        _client.NoDelay = true;
        _stream = client.GetStream();
        _ = Task.Run(ReadLoop);
        _ = Task.Run(WriteLoop);
    }

    private async Task ReadLoop()
    {
        var header = new byte[4];
        try
        {
            while (true)
            {
                await _stream.ReadExactlyAsync(header);
                var length = (int)BinaryPrimitives.ReadUInt32BigEndian(header);
                if (length > LocalLink.MaxFrame) break;
                var body = new byte[length];
                await _stream.ReadExactlyAsync(body);
                await _incoming.Writer.WriteAsync(body);
            }
        }
        catch (Exception) { }
        Close();
    }

    private async Task WriteLoop()
    {
        var header = new byte[4];
        try
        {
            await foreach (var frame in _outgoing.Reader.ReadAllAsync())
            {
                BinaryPrimitives.WriteUInt32BigEndian(header, (uint)frame.Length);
                await _stream.WriteAsync(header);
                await _stream.WriteAsync(frame);
            }
        }
        catch (Exception) { Close(); }
    }

    public void Send(byte[] data)
    {
        if (Volatile.Read(ref _closed) == 0) _outgoing.Writer.TryWrite(data);
    }

    public async ValueTask<byte[]?> ReceiveAsync(CancellationToken ct)
    {
        try { return await _incoming.Reader.ReadAsync(ct); }
        catch (ChannelClosedException) { return null; }
    }

    public void Close()
    {
        if (Interlocked.Exchange(ref _closed, 1) == 1) return;
        _incoming.Writer.TryComplete();
        _outgoing.Writer.TryComplete();
        try { _client.Close(); } catch { }
    }
}

/// Accepts direct sessions on any free port; each connection gets a FileServer like a relay session.
public sealed class LocalListener(Action<TcpPipe> onSession) : IDisposable
{
    private readonly TcpListener _listener = new(IPAddress.Any, 0);
    public int Port { get; private set; }

    public void Start()
    {
        _listener.Start();
        Port = ((IPEndPoint)_listener.LocalEndpoint).Port;
        _ = Task.Run(async () =>
        {
            while (true)
            {
                TcpClient client;
                try { client = await _listener.AcceptTcpClientAsync(); } catch (Exception) { return; }
                try { onSession(new TcpPipe(client)); } catch (Exception) { client.Dispose(); }
            }
        });
    }

    public List<string> Endpoints() => [.. LocalLink.Addresses().Select(a => $"{a}:{Port}")];

    public void Dispose() => _listener.Stop();
}
