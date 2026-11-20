using System.Collections.Concurrent;
using System.Net.WebSockets;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;

namespace Teleport.Core;

/// This PC's live connection to its relay mailbox (SPEC.md "Mac mailbox"; a Windows PC
/// uses the same mailbox). Proves ownership by signing the challenge with the TPM key,
/// pings to notice dead connections, and reconnects with backoff.
public sealed class MailboxConnection : IAsyncDisposable
{
    public enum Status { Connecting, Online, Offline }

    private readonly TeleportClient _teleport;
    private readonly Func<FileServer.Options> _fileOptions;
    private readonly CancellationTokenSource _stop = new();
    private readonly ConcurrentDictionary<string, MailboxSessionPipe> _sessions = new();
    private readonly ConcurrentDictionary<string, string> _browsers = new();
    private readonly SemaphoreSlim _sendLock = new(1, 1);
    private ClientWebSocket? _socket;
    private Task? _loop;
    private CancellationTokenSource? _kick;

    public Status State { get; private set; } = Status.Connecting;
    public string? OfflineReason { get; private set; }
    public DateTimeOffset? OnlineSince { get; private set; }

    public event Action? StateChanged;
    /// An envelope delivered by a phone (JSON).
    public event Func<string, Task>? Envelope;
    /// Names of the phones browsing this PC right now.
    public event Action<IReadOnlyList<string>>? BrowsersChanged;
    public Func<string, int, Task<byte[]?>>? Thumbnailer { get; set; }
    public Action<string>? Log { get; set; }

    public MailboxConnection(TeleportClient teleport, Func<FileServer.Options> fileOptions)
    {
        _teleport = teleport;
        _fileOptions = fileOptions;
    }

    public void Start() => _loop ??= Task.Run(RunAsync);

    /// After wake or a network change: skip the backoff and reconnect now.
    public void ReconnectNow() => _kick?.Cancel();

    private void SetState(Status s, string? reason = null)
    {
        State = s;
        OfflineReason = reason;
        OnlineSince = s == Status.Online ? DateTimeOffset.Now : null;
        Log?.Invoke($"mailbox {_teleport.MyId}: {s}{(reason is null ? "" : $" ({reason})")}");
        StateChanged?.Invoke();
    }

    private async Task RunAsync()
    {
        var backoff = TimeSpan.FromSeconds(1);
        while (!_stop.IsCancellationRequested)
        {
            SetState(Status.Connecting);
            string reason;
            try
            {
                reason = await ConnectOnceAsync(() => backoff = TimeSpan.FromSeconds(1));
            }
            catch (Exception e) when (e is WebSocketException or HttpRequestException or IOException or OperationCanceledException)
            {
                reason = e is OperationCanceledException ? "Connection timed out" : "Can't reach the relay";
            }
            EndSessions();
            if (_stop.IsCancellationRequested) break;
            SetState(Status.Offline, reason);
            _kick = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
            try { await Task.Delay(backoff, _kick.Token); } catch (OperationCanceledException) { }
            backoff = TimeSpan.FromSeconds(Math.Min(backoff.TotalSeconds * 2, 60));
        }
    }

    /// One connection's life. Returns why it ended.
    private async Task<string> ConnectOnceAsync(Action onReady)
    {
        using var socket = new ClientWebSocket();
        socket.Options.SetRequestHeader("Authorization", _teleport.Relay.Authorization);
        socket.Options.KeepAliveInterval = TimeSpan.Zero;  // we ping ourselves (the relay auto-answers "ping")
        using var connectTimeout = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
        connectTimeout.CancelAfter(TimeSpan.FromSeconds(30));
        await socket.ConnectAsync(_teleport.Relay.MailboxConnectUri(_teleport.MyId), connectTimeout.Token);
        _socket = socket;

        using var life = CancellationTokenSource.CreateLinkedTokenSource(_stop.Token);
        var lastHeard = DateTime.UtcNow;
        var pinger = Task.Run(async () =>
        {
            // Every 20 s; if nothing came back for 50 s the connection is dead (it never errors by itself).
            while (!life.IsCancellationRequested)
            {
                try { await Task.Delay(TimeSpan.FromSeconds(20), life.Token); } catch (OperationCanceledException) { return; }
                if (DateTime.UtcNow - lastHeard > TimeSpan.FromSeconds(50)) { Log?.Invoke("mailbox: no pong for 50 s"); life.Cancel(); return; }
                try { await SendTextAsync("ping", life.Token); } catch (Exception) { life.Cancel(); return; }
            }
        });

        var buffer = new byte[64 * 1024];
        var message = new MemoryStream();
        try
        {
            while (true)
            {
                var result = await socket.ReceiveAsync(buffer, life.Token);
                if (result.MessageType == WebSocketMessageType.Close)
                {
                    return (int?)socket.CloseStatus switch
                    {
                        4000 => "Connected from another session",
                        4401 => "The relay rejected this PC's key",
                        4408 => "Sign-in to the relay timed out",
                        _ => "The relay closed the connection",
                    };
                }
                message.Write(buffer, 0, result.Count);
                if (!result.EndOfMessage) continue;
                lastHeard = DateTime.UtcNow;
                var data = message.ToArray();
                message.SetLength(0);
                if (result.MessageType == WebSocketMessageType.Binary) DeliverSessionFrame(data);
                else await HandleTextAsync(Encoding.UTF8.GetString(data), onReady, life.Token);
            }
        }
        catch (OperationCanceledException) when (!_stop.IsCancellationRequested)
        {
            return "Connection lost";
        }
        finally
        {
            life.Cancel();
            _socket = null;
            try { await pinger; } catch { }
        }
    }

    private async Task HandleTextAsync(string text, Action onReady, CancellationToken ct)
    {
        if (text == "pong") return;
        JsonNode? obj;
        try { obj = JsonNode.Parse(text); } catch (Exception) { return; }
        switch (obj?["t"]?.GetValue<string>())
        {
            case "challenge":
                var nonce = obj["nonce"]?.GetValue<string>() ?? "";
                var sig = _teleport.Signing.Sign(Encoding.UTF8.GetBytes($"teleport/v1/mailbox|{_teleport.MyId}|{nonce}"));
                await SendTextAsync(Wire.Serialize(new { t = "auth", ks = B64.Url(_teleport.Signing.PublicKey), sig = B64.Url(sig) }), ct);
                break;
            case "ready":
                onReady();
                SetState(Status.Online);
                break;
            case "env":
                if (obj["env"] is { } env && Envelope is { } handler)
                {
                    var json = env.ToJsonString();
                    _ = Task.Run(async () => { try { await handler(json); } catch (Exception e) { Log?.Invoke($"envelope: {e.Message}"); } });
                }
                break;
            case "open":
                if (obj["sid"]?.GetValue<string>() is { } sid && B64.TryFromUrl(sid, out var raw) && raw.Length == 16) OpenSession(sid, raw);
                break;
            case "close":
                if (obj["sid"]?.GetValue<string>() is { } closed && _sessions.TryRemove(closed, out var pipe)) { pipe.Finish(); ReportBrowsers(closed, null); }
                break;
        }
    }

    private async Task SendTextAsync(string text, CancellationToken ct) => await SendAsync(Encoding.UTF8.GetBytes(text), WebSocketMessageType.Text, ct);

    internal async Task SendAsync(byte[] data, WebSocketMessageType type, CancellationToken ct)
    {
        var socket = _socket ?? throw new WebSocketException("not connected");
        await _sendLock.WaitAsync(ct);
        try { await socket.SendAsync(data, type, true, ct); }
        finally { _sendLock.Release(); }
    }

    // ---------- file sessions ----------

    private void OpenSession(string sid, byte[] raw)
    {
        var pipe = new MailboxSessionPipe(this, sid, raw);
        _sessions[sid] = pipe;
        var server = new FileServer(pipe, _teleport.Signing, _teleport.MyId, _fileOptions(),
            id => _teleport.Store.Peers.GetValueOrDefault(id)) { Thumbnailer = Thumbnailer };
        Log?.Invoke("file session opened");
        _ = Task.Run(async () =>
        {
            var watch = Task.Run(async () =>
            {
                for (var i = 0; i < 50 && server.Phone is null; i++) await Task.Delay(200);
                if (server.Phone is { } phone && _sessions.ContainsKey(sid)) ReportBrowsers(sid, phone.Name);
            });
            await server.RunAsync();
            _sessions.TryRemove(sid, out _);
            ReportBrowsers(sid, null);
            Log?.Invoke("file session closed");
        });
    }

    private void DeliverSessionFrame(byte[] data)
    {
        if (data.Length < 16) return;
        var sid = B64.Url(data.AsSpan(0, 16));
        if (_sessions.TryGetValue(sid, out var pipe)) pipe.Deliver(data[16..]);
    }

    private void EndSessions()
    {
        foreach (var (sid, pipe) in _sessions) { pipe.Finish(); _sessions.TryRemove(sid, out _); }
        _browsers.Clear();
        BrowsersChanged?.Invoke([]);
    }

    private void ReportBrowsers(string sid, string? name)
    {
        if (name is null) _browsers.TryRemove(sid, out _); else _browsers[sid] = name;
        BrowsersChanged?.Invoke([.. _browsers.Values.Distinct().Order()]);
    }

    /// Closes sessions with no traffic for 5 minutes, so a phone that vanished can't stay "browsing".
    public void CloseIdleSessions()
    {
        foreach (var (sid, pipe) in _sessions)
            if (pipe.IdleFor > TimeSpan.FromMinutes(5)) { pipe.Close(); _sessions.TryRemove(sid, out _); ReportBrowsers(sid, null); }
    }

    public async ValueTask DisposeAsync()
    {
        _stop.Cancel();
        if (_loop is not null) try { await _loop; } catch { }
    }

    /// One session's pipe through the mailbox socket: frames go out as sid ‖ payload.
    private sealed class MailboxSessionPipe(MailboxConnection owner, string sid, byte[] raw) : ISessionPipe
    {
        private readonly Channel<byte[]> _incoming = Channel.CreateUnbounded<byte[]>();
        private readonly Channel<byte[]> _outgoing = Channel.CreateUnbounded<byte[]>(new UnboundedChannelOptions { SingleReader = true });
        private long _lastActivity = DateTime.UtcNow.Ticks;
        private int _closed;
        private Task? _writer;

        public TimeSpan IdleFor => DateTime.UtcNow - new DateTime(Interlocked.Read(ref _lastActivity), DateTimeKind.Utc);

        public void Deliver(byte[] data) { Interlocked.Exchange(ref _lastActivity, DateTime.UtcNow.Ticks); _incoming.Writer.TryWrite(data); }

        /// The phone went away (or the mailbox connection did).
        public void Finish() { Interlocked.Exchange(ref _closed, 1); _incoming.Writer.TryComplete(); _outgoing.Writer.TryComplete(); }

        public async ValueTask<byte[]?> ReceiveAsync(CancellationToken ct)
        {
            try { return await _incoming.Reader.ReadAsync(ct); }
            catch (ChannelClosedException) { return null; }
        }

        // Ordered: one writer drains the queue onto the socket.
        public void Send(byte[] data)
        {
            if (Volatile.Read(ref _closed) == 1) return;
            Interlocked.Exchange(ref _lastActivity, DateTime.UtcNow.Ticks);
            _outgoing.Writer.TryWrite([.. raw, .. data]);
            _writer ??= Task.Run(async () =>
            {
                await foreach (var frame in _outgoing.Reader.ReadAllAsync())
                {
                    try { await owner.SendAsync(frame, WebSocketMessageType.Binary, CancellationToken.None); }
                    catch (Exception) { Finish(); return; }
                }
            });
        }

        /// The server is done: tell the mailbox to hang up on the phone.
        public void Close()
        {
            if (Interlocked.Exchange(ref _closed, 1) == 1) { _incoming.Writer.TryComplete(); return; }
            _incoming.Writer.TryComplete();
            _outgoing.Writer.TryComplete();
            _ = Task.Run(async () =>
            {
                if (_writer is not null) try { await _writer; } catch { }
                try { await owner.SendAsync(Encoding.UTF8.GetBytes($$"""{"t":"close","sid":"{{sid}}"}"""), WebSocketMessageType.Text, CancellationToken.None); } catch { }
            });
        }
    }
}
