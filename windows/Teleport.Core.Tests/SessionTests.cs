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

    private async Task<Phone> ConnectAsync(bool trusted = true, bool showHidden = false)
    {
        MemPipe phoneEnd = new(), pcEnd = new();
        phoneEnd.Peer = pcEnd; pcEnd.Peer = phoneEnd;
        var phonePeer = new Peer("Phone", "ios", B64.Url(new SoftwareAgreementKey().PublicKey), B64.Url(_phoneKs.PublicKey));
        var server = new FileServer(pcEnd, _pcKs, Mailbox, new FileServer.Options(_home, showHidden),
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
}
