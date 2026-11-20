using System.Security.Cryptography;
using System.Text.Encodings.Web;
using System.Text.Json;
using System.Text.Json.Serialization;

namespace Teleport.Core;

/// base64url without padding (SPEC.md "Notation").
public static class B64
{
    public static string Url(ReadOnlySpan<byte> bytes) =>
        Convert.ToBase64String(bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_');

    public static byte[] FromUrl(string s)
    {
        var t = s.Replace('-', '+').Replace('_', '/');
        t += (t.Length % 4) switch { 2 => "==", 3 => "=", 0 => "", _ => throw new FormatException("bad base64url") };
        return Convert.FromBase64String(t);
    }

    public static bool TryFromUrl(string? s, out byte[] bytes)
    {
        bytes = [];
        if (s is null) return false;
        try { bytes = FromUrl(s); return true; } catch (FormatException) { return false; }
    }
}

/// One JSON style for the wire: camelCase names, nulls omitted, no needless escaping
/// (matches JSON.stringify in the TS reference, so byte-exact vectors line up).
public static class Wire
{
    public static readonly JsonSerializerOptions Json = new()
    {
        PropertyNamingPolicy = JsonNamingPolicy.CamelCase,
        DefaultIgnoreCondition = JsonIgnoreCondition.WhenWritingNull,
        Encoder = JavaScriptEncoder.UnsafeRelaxedJsonEscaping,
    };

    public static string Serialize<T>(T value) => JsonSerializer.Serialize(value, Json);
    public static T Deserialize<T>(string json) => JsonSerializer.Deserialize<T>(json, Json) ?? throw new JsonException("null");
}

/// Key agreement: recipients decrypt with it.
public interface IAgreementKey
{
    /// 65-byte uncompressed P-256 point.
    byte[] PublicKey { get; }
    /// Raw ECDH secret (x coordinate, 32 bytes) with `peer` (65-byte point).
    byte[] SharedSecret(byte[] peer);
}

/// Signing: senders authenticate with it.
public interface ISigningKey
{
    byte[] PublicKey { get; }
    /// ECDSA P-256 / SHA-256, raw r‖s (64 bytes).
    byte[] Sign(byte[] data);
}

public static class P256
{
    public static readonly ECCurve Curve = ECCurve.NamedCurves.nistP256;

    public static byte[] Raw(ECParameters p) => [0x04, .. p.Q.X!, .. p.Q.Y!];

    public static ECParameters FromRaw(byte[] raw, byte[]? d = null)
    {
        if (raw.Length != 65 || raw[0] != 0x04) throw new CryptographicException("expected a 65-byte uncompressed P-256 point");
        return new ECParameters { Curve = Curve, Q = new ECPoint { X = raw[1..33], Y = raw[33..65] }, D = d };
    }

    public static bool Verify(byte[] publicKey, byte[] data, byte[] rawSig)
    {
        try
        {
            using var ecdsa = ECDsa.Create(FromRaw(publicKey));
            return ecdsa.VerifyData(data, rawSig, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
        }
        catch (CryptographicException) { return false; }
    }
}

/// In-memory P-256 keys: ephemerals, tests, and the fallback when there's no TPM.
public sealed class SoftwareAgreementKey : IAgreementKey, IDisposable
{
    private readonly ECDiffieHellman _key;
    public SoftwareAgreementKey() : this(ECDiffieHellman.Create(P256.Curve)) { }
    public SoftwareAgreementKey(ECDiffieHellman key) { _key = key; PublicKey = P256.Raw(key.ExportParameters(false)); }
    public static SoftwareAgreementKey FromRaw(byte[] d, byte[] pub) => new(ECDiffieHellman.Create(P256.FromRaw(pub, d)));
    public byte[] PublicKey { get; }
    public byte[] PrivateScalar => _key.ExportParameters(true).D!;

    public byte[] SharedSecret(byte[] peer)
    {
        using var other = ECDiffieHellman.Create(P256.FromRaw(peer));
        return _key.DeriveRawSecretAgreement(other.PublicKey);
    }

    public void Dispose() => _key.Dispose();
}

public sealed class SoftwareSigningKey : ISigningKey, IDisposable
{
    private readonly ECDsa _key;
    public SoftwareSigningKey() : this(ECDsa.Create(P256.Curve)) { }
    public SoftwareSigningKey(ECDsa key) { _key = key; PublicKey = P256.Raw(key.ExportParameters(false)); }
    public static SoftwareSigningKey FromRaw(byte[] d, byte[] pub) => new(ECDsa.Create(P256.FromRaw(pub, d)));
    public byte[] PublicKey { get; }
    public byte[] PrivateScalar => _key.ExportParameters(true).D!;

    public byte[] Sign(byte[] data) =>
        _key.SignData(data, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);

    public void Dispose() => _key.Dispose();
}

public static class Primitives
{
    public static byte[] Random(int n) => RandomNumberGenerator.GetBytes(n);
    public static byte[] Sha256(byte[] b) => SHA256.HashData(b);

    public static byte[] Hkdf(byte[] ikm, byte[] salt, byte[] info, int length) =>
        HKDF.DeriveKey(HashAlgorithmName.SHA256, ikm, length, salt, info);

    /// AES-256-GCM: returns ciphertext ‖ 16-byte tag.
    public static byte[] Seal(byte[] key, byte[] nonce, byte[] plaintext, byte[] aad)
    {
        using var gcm = new AesGcm(key, 16);
        var output = new byte[plaintext.Length + 16];
        gcm.Encrypt(nonce, plaintext, output.AsSpan(0, plaintext.Length), output.AsSpan(plaintext.Length), aad);
        return output;
    }

    /// Opens ciphertext ‖ tag; throws CryptographicException if it doesn't authenticate.
    public static byte[] Open(byte[] key, byte[] nonce, byte[] sealedBox, byte[] aad)
    {
        if (sealedBox.Length < 16) throw new CryptographicException("too short");
        using var gcm = new AesGcm(key, 16);
        var plain = new byte[sealedBox.Length - 16];
        gcm.Decrypt(nonce, sealedBox.AsSpan(0, plain.Length), sealedBox.AsSpan(plain.Length), plain, aad);
        return plain;
    }
}
