using System.Buffers.Binary;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Teleport.Core;

// File sessions: SPEC.md "File sessions (v2)". Signed ephemeral ECDH through the
// computer's relay mailbox, then AES-GCM frames with implicit counters.

public static class SessionCrypto
{
    private static readonly byte[] Info = "teleport/v1/session"u8.ToArray();
    public const uint PhoneToMac = 1;
    public const uint MacToPhone = 2;
    public const int ChunkSize = 256 * 1024;
    public const long Window = 2L * 1024 * 1024;
    public const long AckEvery = 1024L * 1024;

    public sealed record Hello(string T, int V, string From, string Epk, string N, long Ts, string Sig);
    public sealed record Accept(string Epk, string N, string Sig, string T = "accept");

    public static byte[] HelloTranscript(string mailbox, string from, string epk, string n, long ts) =>
        Encoding.UTF8.GetBytes($"teleport/v1/session|{mailbox}|{from}|{epk}|{n}|{ts}");

    public static byte[] AcceptTranscript(byte[] hello, string epk, string n) =>
        [.. hello, .. Encoding.UTF8.GetBytes($"|{epk}|{n}")];

    /// phone→computer key, computer→phone key.
    public static (byte[] P2M, byte[] M2P) Keys(byte[] sharedSecret, byte[] acceptTranscript)
    {
        var okm = Primitives.Hkdf(sharedSecret, SHA256.HashData(acceptTranscript), Info, 64);
        return (okm[..32], okm[32..]);
    }
}

/// One direction of a session: AES-256-GCM, nonce = dir (u32 BE) ‖ counter (u64 BE).
public sealed class FrameCipher(byte[] key, uint dir, ulong counter = 0)
{
    private ulong _counter = counter;

    private byte[] Nonce()
    {
        var n = new byte[12];
        BinaryPrimitives.WriteUInt32BigEndian(n, dir);
        BinaryPrimitives.WriteUInt64BigEndian(n.AsSpan(4), _counter);
        return n;
    }

    public byte[] Seal(byte[] plaintext) { var f = Primitives.Seal(key, Nonce(), plaintext, []); _counter++; return f; }
    public byte[] Open(byte[] frame) { var p = Primitives.Open(key, Nonce(), frame, []); _counter++; return p; }
}

public sealed record FileEntry(string Name, bool Dir, long Size, long Mtime);

/// A control message: one flat shape for every `op`; unused fields are omitted.
public sealed record Control(string Op, uint Id)
{
    public string? Path { get; init; }
    public long? Offset { get; init; }
    public long? Size { get; init; }
    public string? Mime { get; init; }
    public string? Sha256 { get; init; }
    public string? Name { get; init; }
    public string? Dir { get; init; }
    public long? Bytes { get; init; }
    public int? Px { get; init; }
    public List<FileEntry>? Entries { get; init; }
    public string? Code { get; init; }
    public string? Message { get; init; }

    public static Control Error(uint id, string code, string message) => new("error", id) { Code = code, Message = message };
}

/// A decrypted frame: 0x01 ‖ JSON, or 0x02 ‖ id ‖ bytes.
public abstract record SessionFrame(uint Id)
{
    public sealed record Ctl(Control C) : SessionFrame(C.Id);
    public sealed record Data(uint DataId, byte[] Bytes) : SessionFrame(DataId);

    public byte[] Encode() => this switch
    {
        Ctl c => [1, .. Encoding.UTF8.GetBytes(Wire.Serialize(c.C))],
        Data d => Concat(d.DataId, d.Bytes),
        _ => throw new InvalidOperationException(),
    };

    private static byte[] Concat(uint id, byte[] bytes)
    {
        var b = new byte[5 + bytes.Length];
        b[0] = 2;
        BinaryPrimitives.WriteUInt32BigEndian(b.AsSpan(1), id);
        bytes.CopyTo(b, 5);
        return b;
    }

    public static SessionFrame Decode(byte[] p)
    {
        if (p.Length >= 1 && p[0] == 1) return new Ctl(Wire.Deserialize<Control>(Encoding.UTF8.GetString(p, 1, p.Length - 1)));
        if (p.Length >= 5 && p[0] == 2) return new Data(BinaryPrimitives.ReadUInt32BigEndian(p.AsSpan(1)), p[5..]);
        throw new FormatException("bad frame");
    }
}

/// An ordered byte pipe to the phone (a mailbox session, or in-memory in tests).
public interface ISessionPipe
{
    /// Queues a message; messages arrive in the order they were queued.
    void Send(byte[] data);
    /// Next message, or null once the pipe has closed.
    ValueTask<byte[]?> ReceiveAsync(CancellationToken ct);
    void Close();
}

/// Lexical path rules (SPEC.md "Path rules") plus what Windows needs on top: no
/// backslashes, drive letters or `:` streams, no reserved device names, and no names
/// Windows would silently alter (trailing dots or spaces).
public static class FilePaths
{
    private static readonly HashSet<string> Reserved = new(StringComparer.OrdinalIgnoreCase)
    {
        "CON", "PRN", "AUX", "NUL", "CONIN$", "CONOUT$",
        "COM1", "COM2", "COM3", "COM4", "COM5", "COM6", "COM7", "COM8", "COM9",
        "LPT1", "LPT2", "LPT3", "LPT4", "LPT5", "LPT6", "LPT7", "LPT8", "LPT9",
    };
    private static readonly char[] Invalid = ['\\', ':', '*', '?', '"', '<', '>', '|'];

    /// The normalised relative path, or null if it isn't allowed. `windows` adds the Windows rules.
    public static string? Check(string path, bool showHidden, bool windows = true)
    {
        if (path.StartsWith('/') || path.Contains('\0')) return null;
        var parts = path.Split('/', StringSplitOptions.RemoveEmptyEntries).Where(p => p != ".").ToList();
        if (parts.Contains("..")) return null;
        if (windows && parts.Any(p => !ValidName(p))) return null;
        if (!showHidden && parts.Select((p, i) => Hidden(p, i == 0, windows)).Any(h => h)) return null;
        return string.Join('/', parts);
    }

    /// One file or folder name a phone may create or name.
    public static bool ValidName(string name)
    {
        if (name.Length == 0 || name is "." or "..") return false;
        if (name.IndexOfAny(Invalid) >= 0 || name.Any(c => c < 0x20)) return false;
        if (name.EndsWith('.') || name.EndsWith(' ')) return false;
        var stem = name.Split('.')[0].TrimEnd();
        return !Reserved.Contains(stem);
    }

    /// Dotfiles everywhere; at the top of the home folder, the app-data folder too
    /// (`Library` on a Mac, `AppData` on Windows).
    public static bool Hidden(string name, bool topLevel, bool windows = true) =>
        name.StartsWith('.') || (topLevel && (windows ? name.Equals("AppData", StringComparison.OrdinalIgnoreCase) : name == "Library"));
}
