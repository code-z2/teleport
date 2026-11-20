using System.Security.Cryptography;
using System.Text;
using System.Text.Json;

namespace Teleport.Core;

/// Teleport wire protocol v1 (SPEC.md "Envelope").
public sealed record Envelope(int V, string Id, long Ts, string K, string From, string Epk, string N, string Ct, string Sig)
{
    public const int MaxBytes = 3000;
    public static readonly string[] Kinds = [Kind.Text, Kind.Blob, Kind.Peer, Kind.Pair, Kind.PairOk, Kind.PairNo];

    /// The signed and authenticated header bytes. Not part of the JSON: the relay accepts
    /// only the nine wire fields.
    [System.Text.Json.Serialization.JsonIgnore]
    public byte[] Header => Encoding.UTF8.GetBytes($"teleport/v1|{Id}|{Ts}|{K}|{From}");

    public string ToJson() => Wire.Serialize(this);
    public static Envelope Parse(string json) => Wire.Deserialize<Envelope>(json);
}

public static class Kind
{
    public const string Text = "text";
    public const string Blob = "blob";
    public const string Peer = "peer";
    public const string Pair = "pair";
    public const string PairOk = "pair-ok";
    public const string PairNo = "pair-no";
}

public sealed class OpenException(string code) : Exception(code)
{
    public string Code { get; } = code;
}

/// Plaintext of a `blob` envelope.
public sealed record BlobPointer(string Id, string Mime, long Size, string Key, string N);

/// Plaintext of a `peer` envelope. Missing fields keep their old values.
public sealed record PeerUpdate(string? Name = null, string? Fcm = null, string? La = null, string? Mailbox = null);

/// Plaintext of a `pair` envelope. The card is a string so the proof covers exact bytes.
public sealed record PairBody(string Card, string Proof);

public static class TeleportCrypto
{
    private static readonly byte[] Info = "teleport/v1/aes-256-gcm"u8.ToArray();
    public static readonly byte[] BlobAad = "teleport/v1/blob"u8.ToArray();

    public static string Fingerprint(byte[] pub) => B64.Url(SHA256.HashData(pub).AsSpan(0, 8));

    public static byte[] DeriveKey(byte[] sharedSecret, byte[] epk, byte[] recipientKa) =>
        Primitives.Hkdf(sharedSecret, [.. epk, .. recipientKa], Info, 32);

    /// `id`, `ts`, `ephemeral` and `nonce` are only passed explicitly by tests.
    public static Envelope Seal(string kind, byte[] plaintext, ISigningKey signer, byte[] recipientKa,
        byte[]? id = null, long? ts = null, IAgreementKey? ephemeral = null, byte[]? nonce = null)
    {
        if (!Envelope.Kinds.Contains(kind)) throw new ArgumentException("unknown kind", nameof(kind));
        using var fresh = ephemeral is null ? new SoftwareAgreementKey() : null;
        var eph = ephemeral ?? fresh!;
        var epk = eph.PublicKey;
        var key = DeriveKey(eph.SharedSecret(recipientKa), epk, recipientKa);
        var n = nonce ?? Primitives.Random(12);
        var unsigned = new Envelope(1, B64.Url(id ?? Primitives.Random(16)), ts ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds(),
            kind, Fingerprint(signer.PublicKey), B64.Url(epk), B64.Url(n), "", "");
        var ct = Primitives.Seal(key, n, plaintext, unsigned.Header);
        var sig = signer.Sign([.. unsigned.Header, .. epk, .. n, .. ct]);
        return unsigned with { Ct = B64.Url(ct), Sig = B64.Url(sig) };
    }

    /// Verify signature → freshness → decrypt. Replay checks are the caller's job.
    public static byte[] Open(Envelope env, IAgreementKey ownKa, byte[] senderKs, long? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (env.V != 1) throw new OpenException("version");
        if (!Envelope.Kinds.Contains(env.K)) throw new OpenException("kind");
        if (env.From != Fingerprint(senderKs)) throw new OpenException("peer");
        var (epk, n, ct, sig) = Decode(env);
        if (!P256.Verify(senderKs, [.. env.Header, .. epk, .. n, .. ct], sig)) throw new OpenException("signature");
        if (env.Ts < t - 86_400 || env.Ts > t + 300) throw new OpenException("stale");
        var key = DeriveKey(ownKa.SharedSecret(epk), epk, ownKa.PublicKey);
        try { return Primitives.Open(key, n, ct, env.Header); }
        catch (CryptographicException) { throw new OpenException("decrypt"); }
    }

    private static (byte[] epk, byte[] n, byte[] ct, byte[] sig) Decode(Envelope env)
    {
        if (B64.TryFromUrl(env.Epk, out var epk) && B64.TryFromUrl(env.N, out var n) &&
            B64.TryFromUrl(env.Ct, out var ct) && B64.TryFromUrl(env.Sig, out var sig))
            return (epk, n, ct, sig);
        throw new OpenException("encoding");
    }

    // ---------- pairing v2 (SPEC.md "v2 additions") ----------

    public static byte[] PairProof(byte[] secret, string cardJson) => HMACSHA256.HashData(secret, Encoding.UTF8.GetBytes(cardJson));

    public static byte[] PairPlaintext(string cardJson, byte[] proof) =>
        Encoding.UTF8.GetBytes(Wire.Serialize(new PairBody(cardJson, B64.Url(proof))));

    public sealed record OpenedPair(PairingCard Card, string Json);

    /// Opens a `pair` envelope from a device that isn't paired yet: decrypt, then check the
    /// signature against the key in the card it carries, then the proof against our QR secret.
    public static OpenedPair OpenPair(Envelope env, IAgreementKey ownKa, byte[] secret, long? now = null)
    {
        var t = now ?? DateTimeOffset.UtcNow.ToUnixTimeSeconds();
        if (env.V != 1) throw new OpenException("version");
        if (env.K != Kind.Pair) throw new OpenException("kind");
        var (epk, n, ct, sig) = Decode(env);
        byte[] pt;
        try { pt = Primitives.Open(DeriveKey(ownKa.SharedSecret(epk), epk, ownKa.PublicKey), n, ct, env.Header); }
        catch (CryptographicException) { throw new OpenException("decrypt"); }
        PairBody body; PairingCard card;
        try
        {
            body = Wire.Deserialize<PairBody>(Encoding.UTF8.GetString(pt));
            card = Wire.Deserialize<PairingCard>(body.Card);
        }
        catch (JsonException) { throw new OpenException("encoding"); }
        if (!B64.TryFromUrl(card.Ks, out var ks) || ks.Length != 65) throw new OpenException("encoding");
        if (env.From != Fingerprint(ks)) throw new OpenException("peer");
        if (!P256.Verify(ks, [.. env.Header, .. epk, .. n, .. ct], sig)) throw new OpenException("signature");
        if (env.Ts < t - 86_400 || env.Ts > t + 300) throw new OpenException("stale");
        if (!B64.TryFromUrl(body.Proof, out var proof)) throw new OpenException("encoding");
        if (!CryptographicOperations.FixedTimeEquals(PairProof(secret, body.Card), proof)) throw new OpenException("proof");
        return new OpenedPair(card, body.Card);
    }

    public sealed record SealedBlob(byte[] Ciphertext, byte[] Key, byte[] Nonce);

    public static SealedBlob SealBlob(byte[] bytes)
    {
        var key = Primitives.Random(32);
        var nonce = Primitives.Random(12);
        return new SealedBlob(Primitives.Seal(key, nonce, bytes, BlobAad), key, nonce);
    }

    public static byte[] OpenBlob(byte[] ciphertext, byte[] key, byte[] nonce)
    {
        try { return Primitives.Open(key, nonce, ciphertext, BlobAad); }
        catch (CryptographicException) { throw new OpenException("decrypt"); }
    }
}
