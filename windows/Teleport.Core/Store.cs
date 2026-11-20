using System.Text.Json;

namespace Teleport.Core;

/// Everything Teleport remembers, as one JSON file (public keys and settings only:
/// device keys live in the TPM). Writes are atomic: temp file, then replace.
public sealed class Store
{
    private sealed class State
    {
        public string? DeviceName { get; set; }
        public Dictionary<string, Peer> Peers { get; set; } = [];
        public Dictionary<string, Peer> PendingOutbound { get; set; } = [];
        public Dictionary<string, PairRequest> PairRequests { get; set; } = [];
        public string? PairingSecret { get; set; }
        public long PairingSecretExpires { get; set; }
        public Dictionary<string, long> Seen { get; set; } = [];
        public bool ShowHiddenFiles { get; set; }
        public bool KeepAwakeOnPower { get; set; } = true;
        public bool SaveImages { get; set; } = true;
    }

    private const long PairWindowMs = 10 * 60_000;
    private readonly string _path;
    private readonly object _lock = new();
    private State _state;

    public event Action? Changed;

    public Store(string path)
    {
        _path = path;
        Directory.CreateDirectory(Path.GetDirectoryName(path)!);
        _state = Load();
    }

    private State Load()
    {
        try { return JsonSerializer.Deserialize<State>(File.ReadAllText(_path), Wire.Json) ?? new State(); }
        catch (Exception e) when (e is FileNotFoundException or DirectoryNotFoundException or JsonException) { return new State(); }
    }

    private T Read<T>(Func<State, T> get) { lock (_lock) return get(_state); }

    private void Write(Action<State> change)
    {
        lock (_lock)
        {
            change(_state);
            var tmp = _path + ".tmp";
            File.WriteAllText(tmp, JsonSerializer.Serialize(_state, Wire.Json));
            File.Move(tmp, _path, overwrite: true);
        }
        Changed?.Invoke();
    }

    private static long NowMs => DateTimeOffset.UtcNow.ToUnixTimeMilliseconds();

    public string? DeviceName { get => Read(s => s.DeviceName); set => Write(s => s.DeviceName = value); }
    public bool ShowHiddenFiles { get => Read(s => s.ShowHiddenFiles); set => Write(s => s.ShowHiddenFiles = value); }
    public bool KeepAwakeOnPower { get => Read(s => s.KeepAwakeOnPower); set => Write(s => s.KeepAwakeOnPower = value); }
    public bool SaveImages { get => Read(s => s.SaveImages); set => Write(s => s.SaveImages = value); }

    public IReadOnlyDictionary<string, Peer> Peers => Read(s => new Dictionary<string, Peer>(s.Peers));
    public List<Peer> SortedPeers => [.. Peers.Values.OrderBy(p => p.PairedAt)];
    public void PutPeer(Peer p) => Write(s => { s.Peers[p.Id] = p; s.PendingOutbound.Remove(p.Id); });
    public void RemovePeer(string id) => Write(s => s.Peers.Remove(id));

    public IReadOnlyDictionary<string, Peer> PendingOutbound =>
        Read(s => s.PendingOutbound.Where(kv => kv.Value.PairedAt + PairWindowMs > NowMs).ToDictionary());
    public void PutPending(Peer p) => Write(s => s.PendingOutbound[p.Id] = p);
    public void RemovePending(string id) => Write(s => s.PendingOutbound.Remove(id));

    public IReadOnlyDictionary<string, PairRequest> PairRequests =>
        Read(s => s.PairRequests.Where(kv => kv.Value.Expires > NowMs).ToDictionary());
    public void PutRequest(PairRequest r) => Write(s => s.PairRequests[r.Id] = r);
    public void RemoveRequest(string id) => Write(s => s.PairRequests.Remove(id));

    /// A fresh one-time QR secret, valid 10 minutes.
    public byte[] NewPairingSecret()
    {
        var secret = Primitives.Random(16);
        Write(s => { s.PairingSecret = B64.Url(secret); s.PairingSecretExpires = NowMs + PairWindowMs; });
        return secret;
    }

    /// The current secret if still valid and unused.
    public byte[]? CurrentPairingSecret() => Read(s =>
        s.PairingSecret is { } ps && s.PairingSecretExpires > NowMs ? B64.FromUrl(ps) : null);

    public void MarkPairingSecretUsed() => Write(s => { s.PairingSecret = null; s.PairingSecretExpires = 0; });

    /// False if `id` was seen in the last 24 h; records it otherwise.
    public bool MarkSeen(string id)
    {
        var fresh = false;
        Write(s =>
        {
            var cutoff = NowMs - 86_400_000;
            foreach (var old in s.Seen.Where(kv => kv.Value < cutoff).Select(kv => kv.Key).ToList()) s.Seen.Remove(old);
            fresh = s.Seen.TryAdd(id, NowMs);
        });
        return fresh;
    }
}
