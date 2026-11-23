using System.Collections.Concurrent;
using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Teleport.Core;

/// The computer's end of one file session: checks the phone's hello, then serves list,
/// download, upload and thumbnail inside the home folder (SPEC.md "File sessions").
public sealed class FileServer
{
    /// `Drives`: extra roots shown at the top of the home listing, by name ("Kingston (D)" →
    /// "D:\\"). Each is fully browsable and, like home, nothing resolves outside it.
    ///
    /// `Folders`: home folders Windows keeps somewhere else ("Pictures" → OneDrive\\Pictures when
    /// OneDrive backs them up). Listed under their usual names in place of the stale local
    /// copy, like File Explorer does.
    public sealed record Options(string Home, bool ShowHidden, bool WindowsRules = true,
        IReadOnlyDictionary<string, string>? Drives = null, IReadOnlyDictionary<string, string>? Folders = null);

    /// Renders a JPEG thumbnail (longest side px) or returns null. Supplied by the app.
    public Func<string, int, Task<byte[]?>>? Thumbnailer { get; init; }

    private readonly ISessionPipe _pipe;
    private readonly ISigningKey _signer;
    private readonly string _mailbox;
    private readonly Func<string, Peer?> _phones;
    private readonly Options _options;
    private readonly string _home;
    private readonly object _sendLock = new();
    private FrameCipher? _tx, _rx;

    private sealed class Download { public CancellationTokenSource Cts = new(); public long Acked; public SemaphoreSlim AckSignal = new(0); }
    private sealed class Upload
    {
        public required string Dir; public required string Name; public required string Partial;
        public required FileStream Stream; public IncrementalHash Hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
        public long Received, Acked;
    }
    private readonly ConcurrentDictionary<uint, Download> _downloads = new();
    private readonly ConcurrentDictionary<uint, Upload> _uploads = new();

    /// The phone that opened this session, once verified.
    public Peer? Phone { get; private set; }

    public FileServer(ISessionPipe pipe, ISigningKey signer, string mailbox, Options options, Func<string, Peer?> phones)
    {
        _pipe = pipe; _signer = signer; _mailbox = mailbox; _options = options; _phones = phones;
        _home = Path.TrimEndingDirectorySeparator(Path.GetFullPath(Resolve(options.Home)));
    }

    /// Runs until the phone goes away, then cleans up partial uploads.
    public async Task RunAsync(Func<long>? now = null, CancellationToken ct = default)
    {
        try
        {
            var first = await _pipe.ReceiveAsync(ct);
            if (first is null || !Accept(first, (now ?? (() => DateTimeOffset.UtcNow.ToUnixTimeSeconds()))())) return;
            while (await _pipe.ReceiveAsync(ct) is { } frame)
            {
                SessionFrame msg;
                try { msg = SessionFrame.Decode(_rx!.Open(frame)); }
                catch (Exception) { break; }  // tampered, replayed or reordered: end the session
                Handle(msg);
            }
        }
        catch (OperationCanceledException) { }
        finally { Finish(); }
    }

    private void Finish()
    {
        foreach (var d in _downloads.Values) { d.Cts.Cancel(); d.AckSignal.Release(); }
        _downloads.Clear();
        foreach (var u in _uploads.Values) Discard(u);
        _uploads.Clear();
        _pipe.Close();
    }

    // ---------- handshake ----------

    private bool Accept(byte[] data, long now)
    {
        bool Refuse(string code) { _pipe.Send(Encoding.UTF8.GetBytes($$"""{"t":"error","code":"{{code}}"}""")); return false; }

        SessionCrypto.Hello? hello;
        try { hello = Wire.Deserialize<SessionCrypto.Hello>(Encoding.UTF8.GetString(data)); }
        catch (JsonException) { return Refuse("version"); }
        if (hello.T != "hello" || hello.V != 1) return Refuse("version");
        var peer = _phones(hello.From);
        if (peer is null || peer.Platform is not ("ios" or "android")) return Refuse("denied");
        var helloT = SessionCrypto.HelloTranscript(_mailbox, hello.From, hello.Epk, hello.N, hello.Ts);
        if (!B64.TryFromUrl(hello.Sig, out var sig) || !B64.TryFromUrl(hello.Epk, out var phoneEpk) ||
            !P256.Verify(peer.KsBytes, helloT, sig)) return Refuse("signature");
        if (Math.Abs(hello.Ts - now) > 300) return Refuse("stale");

        using var eph = new SoftwareAgreementKey();
        var epk = B64.Url(eph.PublicKey);
        var n = B64.Url(Primitives.Random(16));
        var acceptT = SessionCrypto.AcceptTranscript(helloT, epk, n);
        var accept = new SessionCrypto.Accept(epk, n, B64.Url(_signer.Sign(acceptT)));
        var (p2m, m2p) = SessionCrypto.Keys(eph.SharedSecret(phoneEpk), acceptT);
        _tx = new FrameCipher(m2p, SessionCrypto.MacToPhone);
        _rx = new FrameCipher(p2m, SessionCrypto.PhoneToMac);
        Phone = peer;
        _pipe.Send(Encoding.UTF8.GetBytes(Wire.Serialize(accept)));
        return true;
    }

    // ---------- frames ----------

    private void Send(SessionFrame f)
    {
        lock (_sendLock) _pipe.Send(_tx!.Seal(f.Encode()));  // seal + queue atomically keeps counters in order
    }

    private void Fail(uint id, string code, string message) => Send(new SessionFrame.Ctl(Control.Error(id, code, message)));

    private void Handle(SessionFrame frame)
    {
        switch (frame)
        {
            case SessionFrame.Data d: ReceiveUpload(d.DataId, d.Bytes); break;
            case SessionFrame.Ctl { C: var c }:
                switch (c.Op)
                {
                    case "list": List(c); break;
                    case "download": StartDownload(c); break;
                    case "thumbnail": _ = SendThumbnailAsync(c); break;
                    case "read": ReadRange(c); break;
                    case "upload": StartUpload(c); break;
                    case "done": FinishUpload(c); break;
                    case "ack":
                        if (_downloads.TryGetValue(c.Id, out var dl)) { Interlocked.Exchange(ref dl.Acked, Math.Max(dl.Acked, c.Bytes ?? 0)); dl.AckSignal.Release(); }
                        break;
                    case "cancel":
                        if (_downloads.TryRemove(c.Id, out var gone)) { gone.Cts.Cancel(); gone.AckSignal.Release(); }
                        if (_uploads.TryRemove(c.Id, out var up)) Discard(up);
                        break;
                    default: Fail(c.Id, "bad_path", $"Unknown request {c.Op}."); break;
                }
                break;
        }
    }

    // ---------- paths ----------

    private sealed class PathException(string code) : Exception(code) { public string Code { get; } = code; }

    /// Follows junctions and symbolic links to the real path (final target).
    private static string Resolve(string path)
    {
        var full = Path.GetFullPath(path);
        var root = Path.GetPathRoot(full)!;
        var current = root;
        foreach (var part in full[root.Length..].Split(Path.DirectorySeparatorChar, StringSplitOptions.RemoveEmptyEntries))
        {
            current = Path.Combine(current, part);
            FileSystemInfo info = Directory.Exists(current) ? new DirectoryInfo(current) : new FileInfo(current);
            if (info.Exists && info.LinkTarget is not null)
            {
                var target = info.ResolveLinkTarget(returnFinalTarget: true);
                if (target is not null) current = Path.GetFullPath(target.FullName);
            }
        }
        return current;
    }

    private StringComparison Cmp => _options.WindowsRules ? StringComparison.OrdinalIgnoreCase : StringComparison.Ordinal;

    private bool Inside(string real, string root)
    {
        var p = Path.TrimEndingDirectorySeparator(real);
        var r = Path.TrimEndingDirectorySeparator(root);
        // A drive root ("D:\\") trims to "D:" and its children start "D:\\…".
        return p.Equals(r, Cmp) || p.StartsWith(r + Path.DirectorySeparatorChar, Cmp);
    }

    private bool InHome(string real) => Inside(real, _home);

    /// Home or any shared drive (for links found while listing).
    private bool InAllowed(string real) =>
        InHome(real) || Places.Any(p => Inside(real, p.Value));

    private IEnumerable<KeyValuePair<string, string>> Places =>
        (_options.Drives ?? new Dictionary<string, string>()).Concat(_options.Folders ?? new Dictionary<string, string>());

    /// The drive or relocated folder a path's first component names, if any.
    private (string Root, string Remainder)? DrivePath(string clean)
    {
        if (clean.Length == 0) return null;
        var first = clean.Split('/')[0];
        foreach (var (name, root) in Places)
            if (name.Equals(first, Cmp)) return (root, clean.Length > first.Length ? clean[(first.Length + 1)..] : "");
        return null;
    }

    /// A path from a phone → a real path inside home, or inside one of the shared drives.
    private string ResolveRelative(string relative)
    {
        var clean = FilePaths.Check(relative, _options.ShowHidden, _options.WindowsRules) ?? throw new PathException("bad_path");
        var (root, rest) = DrivePath(clean) ?? (_home, clean);
        var joined = rest.Length == 0 ? root : Path.Combine(root, rest.Replace('/', Path.DirectorySeparatorChar));
        var real = Resolve(joined);
        if (!Inside(real, root)) throw new PathException("denied");
        return real;
    }

    private void PathError(uint id, Exception e)
    {
        switch (e)
        {
            case PathException { Code: "bad_path" }: Fail(id, "bad_path", "That location isn't allowed."); break;
            case PathException: Fail(id, "denied", "That's outside the folders this computer shares."); break;
            case FileNotFoundException or DirectoryNotFoundException: Fail(id, "not_found", "That item no longer exists."); break;
            case UnauthorizedAccessException: Fail(id, "denied", "Windows didn't allow Teleport to open that."); break;
            default: Fail(id, "io", e.Message); break;
        }
    }

    /// Hidden from phones unless "show hidden files" is on: dotfiles, AppData at the top,
    /// and anything Windows marks Hidden or System (desktop.ini, legacy junctions…).
    private bool Visible(FileSystemInfo info, bool topLevel)
    {
        if (_options.ShowHidden) return true;
        if (FilePaths.Hidden(info.Name, topLevel, _options.WindowsRules)) return false;
        return !_options.WindowsRules || (info.Attributes & (FileAttributes.Hidden | FileAttributes.System)) == 0;
    }

    // ---------- list ----------

    private void List(Control c)
    {
        try
        {
            var path = c.Path ?? "";
            var dir = new DirectoryInfo(ResolveRelative(path));
            if (!dir.Exists) throw new DirectoryNotFoundException();
            var topLevel = string.IsNullOrEmpty(FilePaths.Check(path, true, _options.WindowsRules));
            var entries = new List<FileEntry>();
            foreach (var item in dir.EnumerateFileSystemInfos())
            {
                try
                {
                    if (!Visible(item, topLevel)) continue;
                    FileSystemInfo target = item;
                    if (item.LinkTarget is not null)
                    {
                        var resolved = item.ResolveLinkTarget(returnFinalTarget: true);
                        if (resolved is null || !resolved.Exists || !InAllowed(Path.GetFullPath(resolved.FullName))) continue;  // links out of shared places aren't shown
                        target = resolved;
                    }
                    var isDir = target is DirectoryInfo;
                    entries.Add(new FileEntry(item.Name, isDir, isDir ? 0 : ((FileInfo)target).Length,
                        new DateTimeOffset(target.LastWriteTimeUtc).ToUnixTimeSeconds()));
                }
                catch (IOException) { } catch (UnauthorizedAccessException) { }
            }
            entries.Sort((a, b) => a.Dir != b.Dir ? (a.Dir ? -1 : 1) : NaturalCompare(a.Name, b.Name));
            if (path.Trim('/').Length == 0)
            {
                // Relocated home folders under their usual names, replacing the stale local copies.
                if (_options.Folders is { Count: > 0 } folders)
                {
                    entries.RemoveAll(e => folders.ContainsKey(e.Name));
                    entries.AddRange(folders.Where(f => Directory.Exists(f.Value))
                        .Select(f => new FileEntry(f.Key, true, 0, new DateTimeOffset(Directory.GetLastWriteTimeUtc(f.Value)).ToUnixTimeSeconds())));
                    entries.Sort((a, b) => a.Dir != b.Dir ? (a.Dir ? -1 : 1) : NaturalCompare(a.Name, b.Name));
                }
                // Then the shared drives first ("Kingston (D)"…).
                if (_options.Drives is { Count: > 0 } drives)
                {
                    var roots = drives.Where(d => Directory.Exists(d.Value)).OrderBy(d => d.Key, StringComparer.OrdinalIgnoreCase)
                        .Select(d => new FileEntry(d.Key, true, 0, new DateTimeOffset(Directory.GetLastWriteTimeUtc(d.Value)).ToUnixTimeSeconds()));
                    entries.RemoveAll(e => drives.ContainsKey(e.Name));
                    entries.InsertRange(0, roots);
                }
            }
            Send(new SessionFrame.Ctl(new Control("entries", c.Id) { Path = path, Entries = entries }));
        }
        catch (Exception e) { PathError(c.Id, e); }
    }

    /// "File 2" before "File 10", case-insensitive, like Explorer.
    private static int NaturalCompare(string a, string b)
    {
        int i = 0, j = 0;
        while (i < a.Length && j < b.Length)
        {
            if (char.IsDigit(a[i]) && char.IsDigit(b[j]))
            {
                int si = i, sj = j;
                while (i < a.Length && char.IsDigit(a[i])) i++;
                while (j < b.Length && char.IsDigit(b[j])) j++;
                var na = a[si..i].TrimStart('0'); var nb = b[sj..j].TrimStart('0');
                if (na.Length != nb.Length) return na.Length.CompareTo(nb.Length);
                var cmp = string.CompareOrdinal(na, nb);
                if (cmp != 0) return cmp;
            }
            else
            {
                var cmp = char.ToUpperInvariant(a[i]).CompareTo(char.ToUpperInvariant(b[j]));
                if (cmp != 0) return cmp;
                i++; j++;
            }
        }
        return (a.Length - i).CompareTo(b.Length - j);
    }

    // ---------- download ----------

    private void StartDownload(Control c)
    {
        string file; long size;
        try
        {
            file = ResolveRelative(c.Path ?? "");
            if (Directory.Exists(file)) { Fail(c.Id, "bad_path", "Folders can't be downloaded."); return; }
            var info = new FileInfo(file);
            if (!info.Exists) throw new FileNotFoundException();
            size = info.Length;
            using (File.OpenRead(file)) { }  // surfaces permission errors now
        }
        catch (Exception e) { PathError(c.Id, e); return; }

        Send(new SessionFrame.Ctl(new Control("meta", c.Id) { Size = size, Mime = Mime.ForName(file) }));
        var offset = Math.Clamp(c.Offset ?? 0, 0, size);
        var d = new Download { Acked = offset };
        _downloads[c.Id] = d;
        _ = Task.Run(() => StreamAsync(c.Id, file, offset, d));
    }

    private async Task StreamAsync(uint id, string file, long offset, Download d)
    {
        try
        {
            await using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete, 1 << 16, useAsync: true);
            using var hash = IncrementalHash.CreateHash(HashAlgorithmName.SHA256);
            var buffer = new byte[SessionCrypto.ChunkSize];
            // The final hash covers the whole file, including any skipped prefix.
            for (long hashed = 0; hashed < offset;)
            {
                var n = await stream.ReadAsync(buffer.AsMemory(0, (int)Math.Min(buffer.Length, offset - hashed)), d.Cts.Token);
                if (n == 0) break;
                hash.AppendData(buffer, 0, n); hashed += n;
            }
            var sent = offset;
            while (true)
            {
                var n = await stream.ReadAsync(buffer, d.Cts.Token);
                if (n == 0) break;
                while (sent - Interlocked.Read(ref d.Acked) >= SessionCrypto.Window)
                    await d.AckSignal.WaitAsync(d.Cts.Token);
                d.Cts.Token.ThrowIfCancellationRequested();
                var chunk = buffer[..n];
                Send(new SessionFrame.Data(id, chunk));
                hash.AppendData(chunk);
                sent += n;
            }
            Send(new SessionFrame.Ctl(new Control("done", id) { Sha256 = B64.Url(hash.GetHashAndReset()) }));
        }
        catch (OperationCanceledException) { }
        catch (Exception e) { PathError(id, e); }
        finally { _downloads.TryRemove(id, out _); }
    }

    // ---------- read (byte ranges, for streaming video) ----------

    /// `read { path, offset, size }`: up to 2 MiB from `offset`, then `done`.
    private void ReadRange(Control c)
    {
        try
        {
            var file = ResolveRelative(c.Path ?? "");
            using var stream = new FileStream(file, FileMode.Open, FileAccess.Read, FileShare.ReadWrite | FileShare.Delete);
            stream.Seek(Math.Max(0, c.Offset ?? 0), SeekOrigin.Begin);
            var left = (int)Math.Min(Math.Max(0, c.Size ?? 0), SessionCrypto.MaxRead);
            var buffer = new byte[SessionCrypto.ChunkSize];
            while (left > 0)
            {
                var n = stream.Read(buffer, 0, Math.Min(left, buffer.Length));
                if (n == 0) break;
                Send(new SessionFrame.Data(c.Id, buffer[..n]));
                left -= n;
            }
            Send(new SessionFrame.Ctl(new Control("done", c.Id)));
        }
        catch (Exception e) { PathError(c.Id, e); }
    }

    // ---------- thumbnail ----------

    private async Task SendThumbnailAsync(Control c)
    {
        string file;
        try
        {
            file = ResolveRelative(c.Path ?? "");
            if (Directory.Exists(file)) { Fail(c.Id, "unsupported", "Folders have no preview."); return; }
        }
        catch (Exception e) { PathError(c.Id, e); return; }

        byte[]? jpeg = null;
        if (Thumbnailer is { } make)
        {
            try { jpeg = await make(file, Math.Clamp(c.Px ?? 512, 64, 1024)); } catch { jpeg = null; }
        }
        if (jpeg is null) { Fail(c.Id, "unsupported", "No preview for this file."); return; }
        Send(new SessionFrame.Ctl(new Control("meta", c.Id) { Size = jpeg.Length, Mime = "image/jpeg" }));
        for (var o = 0; o < jpeg.Length; o += SessionCrypto.ChunkSize)
            Send(new SessionFrame.Data(c.Id, jpeg[o..Math.Min(o + SessionCrypto.ChunkSize, jpeg.Length)]));
        Send(new SessionFrame.Ctl(new Control("done", c.Id) { Sha256 = B64.Url(SHA256.HashData(jpeg)) }));
    }

    // ---------- upload ----------

    private void StartUpload(Control c)
    {
        var name = c.Name ?? "";
        if (!FilePaths.ValidName(name) || (!_options.ShowHidden && FilePaths.Hidden(name, false, _options.WindowsRules)))
        {
            Fail(c.Id, "bad_path", "That file name isn't allowed.");
            return;
        }
        try
        {
            var dir = ResolveRelative(c.Dir ?? "");
            if (!Directory.Exists(dir)) { Fail(c.Id, "not_found", "That folder no longer exists."); return; }
            var partial = Path.Combine(dir, $".teleport-{Guid.NewGuid():N}.part");
            var stream = new FileStream(partial, FileMode.CreateNew, FileAccess.Write, FileShare.None);
            File.SetAttributes(partial, FileAttributes.Hidden);
            var final = UniqueName(name, dir);
            _uploads[c.Id] = new Upload { Dir = dir, Name = final, Partial = partial, Stream = stream };
            Send(new SessionFrame.Ctl(new Control("ready", c.Id) { Name = final }));
        }
        catch (UnauthorizedAccessException) { Fail(c.Id, "denied", "Teleport can't write to that folder."); }
        catch (Exception e) { PathError(c.Id, e); }
    }

    private void ReceiveUpload(uint id, byte[] bytes)
    {
        if (!_uploads.TryGetValue(id, out var u)) return;  // cancelled: drop stragglers
        try { u.Stream.Write(bytes); }
        catch (Exception e) { _uploads.TryRemove(id, out _); Discard(u); PathError(id, e); return; }
        u.Hash.AppendData(bytes);
        u.Received += bytes.Length;
        if (u.Received - u.Acked >= SessionCrypto.AckEvery)
        {
            Send(new SessionFrame.Ctl(new Control("ack", id) { Bytes = u.Received }));
            u.Acked = u.Received;
        }
    }

    private void FinishUpload(Control c)
    {
        if (!_uploads.TryRemove(c.Id, out var u)) return;
        u.Stream.Dispose();
        if (B64.Url(u.Hash.GetHashAndReset()) != c.Sha256)
        {
            Discard(u);
            Fail(c.Id, "hash", "The upload was corrupted in transit.");
            return;
        }
        // Re-check the name: something may have appeared there meanwhile.
        var name = File.Exists(Path.Combine(u.Dir, u.Name)) || Directory.Exists(Path.Combine(u.Dir, u.Name)) ? UniqueName(u.Name, u.Dir) : u.Name;
        try
        {
            var dest = Path.Combine(u.Dir, name);
            File.Move(u.Partial, dest);
            File.SetAttributes(dest, File.GetAttributes(dest) & ~FileAttributes.Hidden);
            Send(new SessionFrame.Ctl(new Control("saved", c.Id) { Name = name }));
        }
        catch (Exception e) { Discard(u); PathError(c.Id, e); }
    }

    private static void Discard(Upload u)
    {
        try { u.Stream.Dispose(); } catch { }
        try { File.Delete(u.Partial); } catch { }
    }

    /// `name`, or `name (2).ext`, `name (3).ext`… whichever is free.
    public static string UniqueName(string name, string dir)
    {
        bool Taken(string n) => File.Exists(Path.Combine(dir, n)) || Directory.Exists(Path.Combine(dir, n));
        if (!Taken(name)) return name;
        var ext = Path.GetExtension(name);
        var stem = Path.GetFileNameWithoutExtension(name);
        for (var i = 2; ; i++)
        {
            var candidate = $"{stem} ({i}){ext}";
            if (!Taken(candidate)) return candidate;
        }
    }
}

public static class Mime
{
    private static readonly Dictionary<string, string> Types = new(StringComparer.OrdinalIgnoreCase)
    {
        [".jpg"] = "image/jpeg", [".jpeg"] = "image/jpeg", [".png"] = "image/png", [".gif"] = "image/gif",
        [".webp"] = "image/webp", [".heic"] = "image/heic", [".bmp"] = "image/bmp", [".svg"] = "image/svg+xml",
        [".pdf"] = "application/pdf", [".txt"] = "text/plain", [".md"] = "text/markdown", [".csv"] = "text/csv",
        [".json"] = "application/json", [".html"] = "text/html", [".zip"] = "application/zip",
        [".mp4"] = "video/mp4", [".mov"] = "video/quicktime", [".mkv"] = "video/x-matroska", [".webm"] = "video/webm",
        [".mp3"] = "audio/mpeg", [".m4a"] = "audio/mp4", [".wav"] = "audio/wav", [".flac"] = "audio/flac",
        [".docx"] = "application/vnd.openxmlformats-officedocument.wordprocessingml.document",
        [".xlsx"] = "application/vnd.openxmlformats-officedocument.spreadsheetml.sheet",
        [".pptx"] = "application/vnd.openxmlformats-officedocument.presentationml.presentation",
    };

    public static string ForName(string path) =>
        Types.TryGetValue(Path.GetExtension(path), out var t) ? t : "application/octet-stream";
}
