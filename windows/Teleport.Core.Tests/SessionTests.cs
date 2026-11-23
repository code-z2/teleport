using System.Security.Cryptography;
using System.Text;
using System.Text.Json.Nodes;
using System.Threading.Channels;
using Teleport.Core;
using Xunit;
using static Teleport.Core.Tests.VectorTests;

namespace Teleport.Core.Tests;

public class SessionVectorTests
{
    private static readonly JsonNode Sv = V["session"]!;

    [Fact]
    public void SignaturesVerify()
    {
        var h = Sv["hello"]!;
        var helloT = SessionCrypto.HelloTranscript(S(Sv["mailbox"]), S(h["from"]), S(h["epk"]), S(h["n"]), h["ts"]!.GetValue<long>());
        Assert.True(P256.Verify(B(V["sender_ks"]!["pub"]), helloT, B(h["sig"])));
        var a = Sv["accept"]!;
        var acceptT = SessionCrypto.AcceptTranscript(helloT, S(a["epk"]), S(a["n"]));
        Assert.Equal(S(Sv["accept_transcript"]), B64.Url(acceptT));
        Assert.True(P256.Verify(B(Sv["mac_ks"]!["pub"]), acceptT, B(a["sig"])));
    }

    [Fact]
    public void KeysMatch()
    {
        var acceptT = B(Sv["accept_transcript"]);
        using var phoneEph = SoftwareAgreementKey.FromRaw(B(Sv["phone_eph"]!["d"]), B(Sv["phone_eph"]!["pub"]));
        using var macEph = SoftwareAgreementKey.FromRaw(B(Sv["mac_eph"]!["d"]), B(Sv["mac_eph"]!["pub"]));
        var phone = SessionCrypto.Keys(phoneEph.SharedSecret(B(Sv["accept"]!["epk"])), acceptT);
        var mac = SessionCrypto.Keys(macEph.SharedSecret(B(Sv["hello"]!["epk"])), acceptT);
        Assert.Equal(S(Sv["k_p2m"]), B64.Url(phone.P2M));
        Assert.Equal(S(Sv["k_m2p"]), B64.Url(mac.M2P));
    }

    [Fact]
    public void FramesMatch()
    {
        foreach (var f in Sv["frames"]!.AsArray())
        {
            var dir = f!["dir"]!.GetValue<uint>();
            var counter = f["counter"]!.GetValue<ulong>();
            var key = B(Sv[dir == 1 ? "k_p2m" : "k_m2p"]);
            Assert.Equal(S(f["frame"]), B64.Url(new FrameCipher(key, dir, counter).Seal(B(f["plaintext"]))));
            Assert.Equal(S(f["plaintext"]), B64.Url(new FrameCipher(key, dir, counter).Open(B(f["frame"]))));
            Assert.ThrowsAny<CryptographicException>(() => new FrameCipher(key, dir, counter + 1).Open(B(f["frame"])));
            SessionFrame.Decode(B(f["plaintext"]));
        }
    }

    [Fact]
    public void MacPathRulesMatch()
    {
        foreach (var p in Sv["paths"]!.AsArray())
        {
            var ok = p!["ok"]?.GetValue<string>();
            Assert.True(ok == FilePaths.Check(S(p["path"]), p["hidden"]!.GetValue<bool>(), windows: false), S(p["path"]));
        }
    }

    [Theory]
    [InlineData("Documents/report.pdf", "Documents/report.pdf")]
    [InlineData("AppData/Roaming", null)]
    [InlineData("Documents/AppData", "Documents/AppData")]
    [InlineData("C:/Windows", null)]
    [InlineData("Documents\\..\\..", null)]
    [InlineData("Documents/file.txt:secret", null)]
    [InlineData("Documents/CON", null)]
    [InlineData("Documents/nul.txt", null)]
    [InlineData("Documents/name.", null)]
    [InlineData("Documents/name ", null)]
    [InlineData("Documents/Console.txt", "Documents/Console.txt")]
    public void WindowsPathRules(string path, string? expected) => Assert.Equal(expected, FilePaths.Check(path, showHidden: false));
}

/// The real FileServer against a small phone-side client, over an in-memory pipe.
public class FileServerTests : IDisposable
{
    private sealed class MemPipe : ISessionPipe
    {
        public readonly Channel<byte[]> Inbox = Channel.CreateUnbounded<byte[]>();
        public MemPipe? Peer;
        public void Send(byte[] data) => Peer?.Inbox.Writer.TryWrite(data);
        public async ValueTask<byte[]?> ReceiveAsync(CancellationToken ct)
        {
            try { return await Inbox.Reader.ReadAsync(ct); } catch (ChannelClosedException) { return null; }
        }
        public void Close() { Inbox.Writer.TryComplete(); Peer?.Inbox.Writer.TryComplete(); }
    }

    /// Minimal phone: handshake, then request/response by id.
    private sealed class Phone(MemPipe pipe, FrameCipher tx, FrameCipher rx)
    {
        private uint _next = 1;

        public static async Task<Phone> ConnectAsync(MemPipe pipe, SoftwareSigningKey ks, string mailbox, byte[] serverKs)
        {
            using var eph = new SoftwareAgreementKey();
            var from = TeleportCrypto.Fingerprint(ks.PublicKey);
            var epk = B64.Url(eph.PublicKey); var n = B64.Url(Primitives.Random(16));
            var ts = DateTimeOffset.UtcNow.ToUnixTimeSeconds();
            var helloT = SessionCrypto.HelloTranscript(mailbox, from, epk, n, ts);
            pipe.Send(Encoding.UTF8.GetBytes(Wire.Serialize(new SessionCrypto.Hello("hello", 1, from, epk, n, ts, B64.Url(ks.Sign(helloT))))));
            var reply = JsonNode.Parse(Encoding.UTF8.GetString((await pipe.ReceiveAsync(default))!))!;
            if (S(reply["t"]) == "error") throw new InvalidOperationException(S(reply["code"]));
            var acceptT = SessionCrypto.AcceptTranscript(helloT, S(reply["epk"]), S(reply["n"]));
            if (!P256.Verify(serverKs, acceptT, B(reply["sig"]))) throw new InvalidOperationException("untrusted");
            var (p2m, m2p) = SessionCrypto.Keys(eph.SharedSecret(B(reply["epk"])), acceptT);
            return new Phone(pipe, new FrameCipher(p2m, 1), new FrameCipher(m2p, 2));
        }

        public void Send(SessionFrame f) => pipe.Send(tx.Seal(f.Encode()));
        public async Task<SessionFrame> NextAsync() => SessionFrame.Decode(rx.Open((await pipe.ReceiveAsync(default))!));
        public uint NewId() => _next++;

        public async Task<Control> RequestAsync(Control c)
        {
            Send(new SessionFrame.Ctl(c));
            return ((SessionFrame.Ctl)await NextAsync()).C;
        }

        public async Task<byte[]> DownloadAsync(string path)
        {
            var id = NewId();
            Send(new SessionFrame.Ctl(new Control("download", id) { Path = path }));
            var data = new MemoryStream(); long acked = 0;
            while (true)
            {
                switch (await NextAsync())
                {
                    case SessionFrame.Data d:
                        data.Write(d.Bytes);
                        if (data.Length - acked >= SessionCrypto.AckEvery) { Send(new SessionFrame.Ctl(new Control("ack", id) { Bytes = data.Length })); acked = data.Length; }
                        break;
                    case SessionFrame.Ctl { C.Op: "done" } done:
                        Assert.Equal(done.C.Sha256, B64.Url(SHA256.HashData(data.ToArray())));
                        return data.ToArray();
                    case SessionFrame.Ctl { C.Op: "error" } err:
                        throw new InvalidOperationException(err.C.Code);
                }
            }
        }

        public async Task<string> UploadAsync(byte[] bytes, string dir, string name)
        {
            var id = NewId();
            var ready = await RequestAsync(new Control("upload", id) { Dir = dir, Name = name, Size = bytes.Length });
            if (ready.Op == "error") throw new InvalidOperationException(ready.Code);
            for (var o = 0; o < bytes.Length; o += SessionCrypto.ChunkSize)
                Send(new SessionFrame.Data(id, bytes[o..Math.Min(o + SessionCrypto.ChunkSize, bytes.Length)]));
            Send(new SessionFrame.Ctl(new Control("done", id) { Sha256 = B64.Url(SHA256.HashData(bytes)) }));
            while (true)
            {
                if (await NextAsync() is SessionFrame.Ctl { C: var c } && c.Op != "ack")
                    return c.Op == "saved" ? c.Name! : throw new InvalidOperationException(c.Code);
            }
        }
    }

    private readonly string _home = Path.Combine(Path.GetTempPath(), "teleport-home-" + Guid.NewGuid().ToString("N"));
    private readonly SoftwareSigningKey _phoneKs = new();
    private readonly SoftwareSigningKey _pcKs = new();
    private const string Mailbox = "rcAUFPmhXeQ";

    public FileServerTests()
    {
        Directory.CreateDirectory(Path.Combine(_home, "Documents", "Notes"));
        Directory.CreateDirectory(Path.Combine(_home, "AppData", "Roaming"));
        Directory.CreateDirectory(Path.Combine(_home, ".ssh"));
        File.WriteAllText(Path.Combine(_home, ".ssh", "id_ed25519"), "secret");
        File.WriteAllText(Path.Combine(_home, "Documents", "a.txt"), "hello");
        File.WriteAllText(Path.Combine(_home, "Documents", "file 10.txt"), "10");
        File.WriteAllText(Path.Combine(_home, "Documents", "file 2.txt"), "2");
        var ini = Path.Combine(_home, "Documents", "desktop.ini");
        File.WriteAllText(ini, "[.ShellClassInfo]");
        File.SetAttributes(ini, FileAttributes.Hidden | FileAttributes.System);
    }

    public void Dispose()
    {
        try { Directory.Delete(_home, recursive: true); } catch { }
    }

    private async Task<Phone> ConnectAsync(bool trusted = true, bool showHidden = false, IReadOnlyDictionary<string, string>? drives = null)
    {
        MemPipe phoneEnd = new(), pcEnd = new();
        phoneEnd.Peer = pcEnd; pcEnd.Peer = phoneEnd;
        var phonePeer = new Peer("Phone", "ios", B64.Url(new SoftwareAgreementKey().PublicKey), B64.Url(_phoneKs.PublicKey));
        var server = new FileServer(pcEnd, _pcKs, Mailbox, new FileServer.Options(_home, showHidden, Drives: drives),
            id => trusted && id == phonePeer.Id ? phonePeer : null);
        _ = Task.Run(() => server.RunAsync());
        return await Phone.ConnectAsync(phoneEnd, _phoneKs, Mailbox, _pcKs.PublicKey);
    }

    [Fact]
    public async Task ListHidesDotfilesAppDataAndSystemFiles()
    {
        var phone = await ConnectAsync();
        var top = await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "" });
        Assert.Equal(["Documents"], top.Entries!.Select(e => e.Name));
        var docs = await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "Documents" });
        Assert.Equal(["Notes", "a.txt", "file 2.txt", "file 10.txt"], docs.Entries!.Select(e => e.Name));  // folders first, natural order
        Assert.Equal("bad_path", (await phone.RequestAsync(new Control("list", phone.NewId()) { Path = ".ssh" })).Code);
        Assert.Equal("bad_path", (await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "AppData" })).Code);
        Assert.Equal("bad_path", (await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "Documents/../.." })).Code);
    }

    [Fact]
    public async Task ShowHiddenRevealsEverything()
    {
        var phone = await ConnectAsync(showHidden: true);
        var top = await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "" });
        Assert.Equal([".ssh", "AppData", "Documents"], top.Entries!.Select(e => e.Name).Order(StringComparer.Ordinal));
    }

    [Fact]
    public async Task UnknownPhoneIsRefused()
    {
        var e = await Assert.ThrowsAsync<InvalidOperationException>(() => ConnectAsync(trusted: false));
        Assert.Equal("denied", e.Message);
    }

    [Fact]
    public async Task LargeDownloadAndUploadRoundTrip()
    {
        var big = new byte[5 * 1024 * 1024 + 12345];
        for (var i = 0; i < big.Length; i++) big[i] = (byte)(i * 31);
        File.WriteAllBytes(Path.Combine(_home, "Documents", "big.bin"), big);
        var phone = await ConnectAsync();

        Assert.Equal(big, await phone.DownloadAsync("Documents/big.bin"));
        Assert.Equal("copy.bin", await phone.UploadAsync(big, "Documents/Notes", "copy.bin"));
        Assert.Equal("copy (2).bin", await phone.UploadAsync(big, "Documents/Notes", "copy.bin"));
        Assert.Equal(big, File.ReadAllBytes(Path.Combine(_home, "Documents", "Notes", "copy (2).bin")));
        // No partial files left behind.
        Assert.Equal(["copy (2).bin", "copy.bin"], Directory.GetFiles(Path.Combine(_home, "Documents", "Notes")).Select(Path.GetFileName).Order());
    }

    [Fact]
    public async Task UploadRejectsBadNames()
    {
        var phone = await ConnectAsync();
        foreach (var name in new[] { "../x", ".bashrc", "CON", "a:b", "trailing." })
        {
            var reply = await phone.RequestAsync(new Control("upload", phone.NewId()) { Dir = "Documents", Name = name, Size = 1 });
            Assert.Equal("bad_path", reply.Code);
        }
    }

    [Fact]
    public async Task JunctionOutOfHomeIsNotFollowed()
    {
        if (!OperatingSystem.IsWindows()) return;
        var outside = Path.Combine(Path.GetTempPath(), "teleport-outside-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(outside);
        File.WriteAllText(Path.Combine(outside, "secret.txt"), "nope");
        Directory.CreateSymbolicLink(Path.Combine(_home, "Documents", "escape"), outside);
        try
        {
            var phone = await ConnectAsync();
            var docs = await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "Documents" });
            Assert.DoesNotContain("escape", docs.Entries!.Select(e => e.Name));
            Assert.Equal("denied", (await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "Documents/escape" })).Code);
        }
        catch (UnauthorizedAccessException) { /* creating symlinks needs Developer Mode or admin */ }
        finally { Directory.Delete(outside, true); }
    }

    [Fact]
    public async Task SharedDrivesAreListedBrowsableAndBounded()
    {
        var drive = Path.Combine(Path.GetTempPath(), "teleport-drive-" + Guid.NewGuid().ToString("N"));
        Directory.CreateDirectory(Path.Combine(drive, "Movies"));
        File.WriteAllText(Path.Combine(drive, "Movies", "clip.mp4"), "video");
        var hidden = Path.Combine(drive, "System Volume Information");
        Directory.CreateDirectory(hidden);
        File.SetAttributes(hidden, FileAttributes.Hidden | FileAttributes.System | FileAttributes.Directory);
        try
        {
            var phone = await ConnectAsync(drives: new Dictionary<string, string> { ["Kingston (D)"] = drive });
            var top = await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "" });
            Assert.Equal("Kingston (D)", top.Entries![0].Name);  // drives first
            var root = await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "Kingston (D)" });
            Assert.Equal(["Movies"], root.Entries!.Select(e => e.Name));  // system folder hidden
            Assert.Equal("video"u8.ToArray(), await phone.DownloadAsync("Kingston (D)/Movies/clip.mp4"));
            Assert.Equal("up.txt", await phone.UploadAsync("hi"u8.ToArray(), "Kingston (D)/Movies", "up.txt"));
            Assert.True(File.Exists(Path.Combine(drive, "Movies", "up.txt")));
            // Can't climb out of the drive.
            Assert.Equal("bad_path", (await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "Kingston (D)/.." })).Code);
            // Unknown drive names are just (missing) home folders.
            Assert.Equal("not_found", (await phone.RequestAsync(new Control("list", phone.NewId()) { Path = "Nope (Z)" })).Code);
        }
        finally { Directory.Delete(drive, true); }
    }

    /// Diagnostic, run by hand on a real PC: TELEPORT_PROBE=1 dotnet test --filter RealHomeProbe.
    /// Lists real folders through the real server and writes what a phone would see.
    [Fact]
    public async Task RealHomeProbe()
    {
        if (Environment.GetEnvironmentVariable("TELEPORT_PROBE") != "1") return;
        var home = Environment.GetFolderPath(Environment.SpecialFolder.UserProfile);
        var drives = DriveInfo.GetDrives().Where(d => d.IsReady && d.DriveType is DriveType.Fixed or DriveType.Removable && !d.Name.StartsWith("C", StringComparison.OrdinalIgnoreCase))
            .ToDictionary(d => $"{(string.IsNullOrEmpty(d.VolumeLabel) ? "Local Disk" : d.VolumeLabel)} ({d.Name[0]})", d => d.RootDirectory.FullName);
        MemPipe phoneEnd = new(), pcEnd = new();
        phoneEnd.Peer = pcEnd; pcEnd.Peer = phoneEnd;
        var phonePeer = new Peer("Phone", "ios", B64.Url(new SoftwareAgreementKey().PublicKey), B64.Url(_phoneKs.PublicKey));
        var folders = new[] { ("Desktop", Environment.SpecialFolder.DesktopDirectory), ("Documents", Environment.SpecialFolder.MyDocuments), ("Pictures", Environment.SpecialFolder.MyPictures) }
            .Select(f => (f.Item1, Environment.GetFolderPath(f.Item2))).Where(f => !f.Item2.Equals(Path.Combine(home, f.Item1), StringComparison.OrdinalIgnoreCase))
            .ToDictionary(f => f.Item1, f => f.Item2);
        var server = new FileServer(pcEnd, _pcKs, Mailbox, new FileServer.Options(home, false, Drives: drives, Folders: folders), id => phonePeer);
        _ = Task.Run(() => server.RunAsync());
        var phone = await Phone.ConnectAsync(phoneEnd, _phoneKs, Mailbox, _pcKs.PublicKey);
        var report = new System.Text.StringBuilder();
        foreach (var path in new[] { "", "Pictures", "Documents", "Desktop", drives.Keys.FirstOrDefault() ?? "" })
        {
            var r = await phone.RequestAsync(new Control("list", phone.NewId()) { Path = path });
            var bytes = System.Text.Encoding.UTF8.GetByteCount(Wire.Serialize(r));
            report.AppendLine($"== '{path}': op={r.Op} code={r.Code} msg={r.Message} entries={r.Entries?.Count} jsonBytes={bytes}");
            foreach (var e in (r.Entries ?? []).Take(path.Length == 0 ? 40 : 6))
                report.AppendLine($"   {(e.Dir ? "D" : "F")} {e.Name}  {DateTimeOffset.FromUnixTimeSeconds(e.Mtime):yyyy-MM-dd}  {e.Size}");
        }
        File.WriteAllText(Path.Combine(Path.GetTempPath(), "teleport-probe.txt"), report.ToString());
    }
}
