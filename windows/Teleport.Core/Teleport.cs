using System.Text;

namespace Teleport.Core;

public abstract record Clip
{
    public sealed record Text(string Value) : Clip;
    public sealed record Bytes(byte[] Data, string Mime) : Clip;
}

public abstract record Received
{
    public sealed record ClipReceived(Clip Clip, string Id, Peer From) : Received;
    /// A large file: verified pointer only. Download it with `DownloadFileAsync`.
    public sealed record FileReceived(BlobPointer Pointer, string Id, Peer From) : Received;
    public sealed record PeerUpdated(Peer Peer) : Received;
    /// Someone scanned our QR code; the user must Allow or Deny.
    public sealed record PairRequested(PairRequest Request) : Received;
    /// A device we scanned accepted.
    public sealed record Paired(Peer Peer) : Received;
    /// A device we scanned clicked Deny.
    public sealed record Declined(Peer Peer) : Received;
}

public sealed class InvalidCodeException() : Exception("That isn't a Teleport pairing code (or it's from an old version).");
public sealed class TooLargeException() : Exception("That's too large to teleport (250 MB max).");

/// High-level pairing, send and receive (the same flow as the phones and the Mac).
public sealed class TeleportClient(IAgreementKey agreement, ISigningKey signing, Store store, RelayClient relay)
{
    /// Clips (text, images) up to this go as one sealed blob and land on the clipboard.
    public const int MaxBlobBytes = 10 * 1024 * 1024;
    /// Files up to this go as chunked blobs (SPEC.md "Large blobs").
    public const long MaxFileBytes = ChunkedBlob.MaxSize;
    private const long PairWindowMs = 10 * 60_000;

    public IAgreementKey Agreement => agreement;
    public ISigningKey Signing => signing;
    public Store Store => store;
    public RelayClient Relay => relay;

    /// `fp(ks)`: this PC's id, and the name of its relay mailbox.
    public string MyId => TeleportCrypto.Fingerprint(signing.PublicKey);

    public PairingCard MyCard(string name) =>
        new(name, "windows", B64.Url(agreement.PublicKey), B64.Url(signing.PublicKey), Mailbox: MyId);

    /// Our QR code with a fresh one-time secret.
    public string QrCode(string name) => (MyCard(name) with { Ps = B64.Url(store.NewPairingSecret()) }).Encoded();

    /// We scanned another device: send it a `pair` request; it becomes a peer when `pair-ok` arrives.
    public async Task<Peer> ScanAsync(string code, string name)
    {
        PairingCard card;
        try { card = PairingCard.Decode(code.Trim()); } catch (OpenException) { throw new InvalidCodeException(); }
        if (card.Ps is null || !B64.TryFromUrl(card.Ps, out var secret)) throw new InvalidCodeException();
        var peer = Peer.From(card);
        if (peer.Id == MyId) throw new InvalidCodeException();
        var myJson = MyCard(name).Json();
        var body = TeleportCrypto.PairPlaintext(myJson, TeleportCrypto.PairProof(secret, myJson));
        await relay.SendAsync(TeleportCrypto.Seal(Kind.Pair, body, signing, peer.KaBytes), peer);
        store.PutPending(peer);
        return peer;
    }

    /// The user clicked Allow: store the device and send `pair-ok`.
    public async Task<Peer> AllowAsync(string requestId, string name)
    {
        var request = store.PairRequests.GetValueOrDefault(requestId) ?? throw new OpenException("expired");
        var peer = Peer.From(Wire.Deserialize<PairingCard>(request.CardJson));
        await relay.SendAsync(TeleportCrypto.Seal(Kind.PairOk, Encoding.UTF8.GetBytes(MyCard(name).Json()), signing, peer.KaBytes), peer);
        store.PutPeer(peer);
        store.RemoveRequest(requestId);
        return peer;
    }

    /// The user clicked Deny: forget the request and tell the device, so it stops waiting.
    public void Deny(string requestId)
    {
        var request = store.PairRequests.GetValueOrDefault(requestId);
        store.RemoveRequest(requestId);
        if (request is null) return;
        var peer = Peer.From(Wire.Deserialize<PairingCard>(request.CardJson));
        _ = Task.Run(async () =>
        {
            try { await relay.SendAsync(TeleportCrypto.Seal(Kind.PairNo, "{}"u8.ToArray(), signing, peer.KaBytes), peer); }
            catch (Exception) { }
        });
    }

    /// Tell every paired device our current name. Returns how many couldn't be reached.
    public async Task<int> AnnounceAsync(string name)
    {
        var body = Encoding.UTF8.GetBytes(Wire.Serialize(new PeerUpdate(Name: name, Mailbox: MyId)));
        var failed = 0;
        foreach (var peer in store.Peers.Values)
        {
            try { await relay.SendAsync(TeleportCrypto.Seal(Kind.Peer, body, signing, peer.KaBytes), peer); }
            catch (Exception) { failed++; }
        }
        return failed;
    }

    // ---------- send ----------

    public async Task SendAsync(Clip clip, Peer to)
    {
        switch (clip)
        {
            case Clip.Text t:
                var bytes = Encoding.UTF8.GetBytes(t.Value);
                var env = TeleportCrypto.Seal(Kind.Text, bytes, signing, to.KaBytes);
                if (Encoding.UTF8.GetByteCount(env.ToJson()) <= Envelope.MaxBytes) await relay.SendAsync(env, to);
                else await SendBlobAsync(bytes, "text/plain; charset=utf-8", to);
                break;
            case Clip.Bytes b:
                await SendBlobAsync(b.Data, b.Mime, to);
                break;
        }
    }

    private async Task SendBlobAsync(byte[] bytes, string mime, Peer to)
    {
        if (bytes.Length + 16 > MaxBlobBytes) throw new TooLargeException();
        var sealedBlob = TeleportCrypto.SealBlob(bytes);
        var id = await relay.PutBlobAsync(sealedBlob.Ciphertext);
        var pointer = new BlobPointer(id, mime, bytes.Length, B64.Url(sealedBlob.Key), B64.Url(sealedBlob.Nonce));
        // Photos get an iPhone Live Activity (Copy / Save); long text stays a plain notification.
        await relay.SendAsync(TeleportCrypto.Seal(Kind.Blob, Encoding.UTF8.GetBytes(Wire.Serialize(pointer)), signing, to.KaBytes), to,
            hint: mime.StartsWith("image/", StringComparison.Ordinal) ? "image" : null);
    }

    /// Sends a file of up to 250 MB as a chunked blob, streaming from `input`: read, sealed
    /// and uploaded 16 MiB at a time.
    public async Task SendFileAsync(Stream input, long size, string mime, string? name, Peer to,
        Action<long, long>? progress = null, CancellationToken ct = default)
    {
        if (size > MaxFileBytes) throw new TooLargeException();
        var key = Primitives.Random(32);
        var n = Primitives.Random(12);
        var chunks = ChunkedBlob.Count(size);
        var total = size + 16L * chunks;
        var upload = await relay.StartUploadAsync(ct);
        try
        {
            var pending = new MemoryStream(ChunkedBlob.Part + ChunkedBlob.Chunk + 64);
            var etags = new List<string>();
            long sent = 0;
            progress?.Invoke(0, total);
            async Task Flush(ReadOnlyMemory<byte> bytes)
            {
                etags.Add(await relay.UploadPartAsync(upload, etags.Count + 1, bytes, ct));
                sent += bytes.Length;
                progress?.Invoke(sent, total);
            }
            var buffer = new byte[ChunkedBlob.Chunk];
            for (var i = 0; i < chunks; i++)
            {
                var read = await input.ReadAtLeastAsync(buffer, buffer.Length, throwOnEndOfStream: false, ct);
                pending.Write(ChunkedBlob.Seal(buffer[..read], i, i == chunks - 1, key, n));
                // Equal-sized parts (R2 requires it); the remainder goes last.
                while (pending.Length >= ChunkedBlob.Part)
                {
                    var all = pending.ToArray();
                    await Flush(all.AsMemory(0, ChunkedBlob.Part));
                    pending.SetLength(0);
                    pending.Write(all, ChunkedBlob.Part, all.Length - ChunkedBlob.Part);
                }
            }
            if (pending.Length > 0 || etags.Count == 0) await Flush(pending.ToArray());
            await relay.CompleteUploadAsync(upload, etags, ct);
        }
        catch
        {
            await relay.AbortUploadAsync(upload);
            throw;
        }
        var pointer = new BlobPointer(upload.Id, mime, size, B64.Url(key), B64.Url(n), ChunkedBlob.Chunk, name);
        await relay.SendAsync(TeleportCrypto.Seal(Kind.Blob, Encoding.UTF8.GetBytes(Wire.Serialize(pointer)), signing, to.KaBytes), to, ct, hint: "file");
    }

    /// Downloads a chunked blob to a temporary file, decrypts it into `destination` a chunk at
    /// a time, then deletes it from the relay.
    public async Task DownloadFileAsync(BlobPointer p, string destination, Action<long, long>? progress = null, CancellationToken ct = default)
    {
        if (p.C is not { } chunk || chunk <= 0 || p.Size > MaxFileBytes) throw new OpenException("encoding");
        var key = B64.FromUrl(p.Key);
        var n = B64.FromUrl(p.N);
        var scratch = Path.GetTempFileName();
        var partial = destination + ".teleport-part";
        try
        {
            await using (var file = File.Create(scratch)) await relay.DownloadBlobAsync(p.Id, file, progress, ct);
            var chunks = ChunkedBlob.Count(p.Size, chunk);
            if (new FileInfo(scratch).Length != p.Size + 16L * chunks) throw new OpenException("decrypt");
            await using (var input = File.OpenRead(scratch))
            await using (var output = File.Create(partial))
            {
                for (var i = 0; i < chunks; i++)
                {
                    var plain = i == chunks - 1 ? (int)(p.Size - (long)i * chunk) : (int)chunk;
                    var sealedChunk = new byte[plain + 16];
                    if (await input.ReadAtLeastAsync(sealedChunk, sealedChunk.Length, throwOnEndOfStream: false, ct) != sealedChunk.Length)
                        throw new OpenException("decrypt");
                    output.Write(ChunkedBlob.Open(sealedChunk, i, i == chunks - 1, key, n));
                }
            }
            File.Move(partial, destination, overwrite: true);
        }
        finally
        {
            File.Delete(scratch);
            if (File.Exists(partial)) File.Delete(partial);
        }
        try { await relay.DeleteBlobAsync(p.Id); } catch (Exception) { }
    }

    // ---------- receive ----------

    /// An envelope delivered through the mailbox. Blobs are downloaded before returning.
    public async Task<Received> ReceiveAsync(string envJson)
    {
        var env = Envelope.Parse(envJson);

        if (env.K == Kind.Pair)
        {
            var secret = store.CurrentPairingSecret() ?? throw new OpenException("proof");
            var opened = TeleportCrypto.OpenPair(env, agreement, secret);
            if (!store.MarkSeen(env.Id)) throw new OpenException("replay");
            store.MarkPairingSecretUsed();
            var request = new PairRequest(env.From, opened.Json, opened.Card.Name, opened.Card.Platform,
                DateTimeOffset.UtcNow.ToUnixTimeMilliseconds() + PairWindowMs);
            store.PutRequest(request);
            return new Received.PairRequested(request);
        }

        // Everything else must come from a paired device (or, for pair-ok, one we scanned).
        var known = store.Peers.GetValueOrDefault(env.From);
        var pending = env.K is Kind.PairOk or Kind.PairNo ? store.PendingOutbound.GetValueOrDefault(env.From) : null;
        var peer = known ?? pending ?? throw new OpenException("peer");
        var pt = TeleportCrypto.Open(env, agreement, peer.KsBytes);
        if (!store.MarkSeen(env.Id)) throw new OpenException("replay");

        switch (env.K)
        {
            case Kind.Text:
                return new Received.ClipReceived(new Clip.Text(Encoding.UTF8.GetString(pt)), env.Id, peer);
            case Kind.Blob:
                var p = Wire.Deserialize<BlobPointer>(Encoding.UTF8.GetString(pt));
                if (p.IsChunked) return new Received.FileReceived(p, env.Id, peer);
                var bytes = TeleportCrypto.OpenBlob(await relay.GetBlobAsync(p.Id), B64.FromUrl(p.Key), B64.FromUrl(p.N));
                try { await relay.DeleteBlobAsync(p.Id); } catch (Exception) { }
                Clip clip = p.Mime.StartsWith("text/", StringComparison.Ordinal)
                    ? new Clip.Text(Encoding.UTF8.GetString(bytes)) : new Clip.Bytes(bytes, p.Mime);
                return new Received.ClipReceived(clip, env.Id, peer);
            case Kind.Peer:
                if (known is null) throw new OpenException("kind");
                var u = Wire.Deserialize<PeerUpdate>(Encoding.UTF8.GetString(pt));
                var updated = peer with { Name = u.Name ?? peer.Name, Fcm = u.Fcm ?? peer.Fcm, La = u.La ?? peer.La, Mailbox = u.Mailbox ?? peer.Mailbox };
                store.PutPeer(updated);
                return new Received.PeerUpdated(updated);
            case Kind.PairOk:
                if (pending is null) throw new OpenException("kind");
                // Their card carries their current name and push address; keys must not change.
                var confirmed = Peer.From(Wire.Deserialize<PairingCard>(Encoding.UTF8.GetString(pt)));
                if (confirmed.Id != peer.Id || confirmed.Ka != peer.Ka) throw new OpenException("peer");
                store.PutPeer(confirmed);
                return new Received.Paired(confirmed);
            case Kind.PairNo:
                if (pending is null || known is not null) throw new OpenException("kind");
                store.RemovePending(pending.Id);
                return new Received.Declined(pending);
            default:
                throw new OpenException("kind");
        }
    }
}
