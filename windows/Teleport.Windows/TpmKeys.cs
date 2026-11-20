using System.Security.Cryptography;
using Teleport.Core;

namespace Teleport.Windows;

/// This PC's two long-lived P-256 keys, created inside the TPM (Microsoft Platform Crypto
/// Provider) so they can't be copied off the machine, like the Secure Enclave and StrongBox
/// on the other devices. Without a usable TPM, falls back to software keys stored in the
/// user's CNG key store (non-exportable).
public static class TpmKeys
{
    private const string AgreementName = "Teleport.ka";
    private const string SigningName = "Teleport.ks";

    public sealed record Loaded(IAgreementKey Agreement, ISigningKey Signing, bool Hardware, string? TpmProblem = null);

    public static Loaded LoadOrCreate()
    {
        string? problem = null;
        foreach (var provider in new[] { CngProvider.MicrosoftPlatformCryptoProvider, CngProvider.MicrosoftSoftwareKeyStorageProvider })
        {
            try
            {
                var ka = Open(AgreementName, CngAlgorithm.ECDiffieHellmanP256, provider);
                var ks = Open(SigningName, CngAlgorithm.ECDsaP256, provider);
                var loaded = new Loaded(new CngAgreementKey(ka), new CngSigningKey(ks), provider == CngProvider.MicrosoftPlatformCryptoProvider, problem);
                SelfCheck(loaded);
                return loaded;
            }
            catch (CryptographicException e) when (provider == CngProvider.MicrosoftPlatformCryptoProvider)
            {
                // No TPM, or it can't do raw ECDH: use software keys instead.
                problem = $"{e.GetType().Name}: {e.Message} (0x{e.HResult:X8}) at {e.StackTrace?.Split('\n').FirstOrDefault()?.Trim()}";
            }
        }
        throw new CryptographicException("Couldn't create this PC's keys.");
    }

    private static CngKey Open(string name, CngAlgorithm algorithm, CngProvider provider)
    {
        if (CngKey.Exists(name, provider)) return CngKey.Open(name, provider);
        return CngKey.Create(algorithm, name, new CngKeyCreationParameters
        {
            Provider = provider,
            ExportPolicy = CngExportPolicies.None,
            KeyCreationOptions = CngKeyCreationOptions.None,  // per-user key
        });
    }

    /// Proves the keys do what the protocol needs before we rely on them.
    private static void SelfCheck(Loaded keys)
    {
        using var other = new SoftwareAgreementKey();
        var a = keys.Agreement.SharedSecret(other.PublicKey);
        var b = other.SharedSecret(keys.Agreement.PublicKey);
        if (!a.SequenceEqual(b)) throw new CryptographicException("ECDH mismatch");
        var data = "teleport self-check"u8.ToArray();
        if (!P256.Verify(keys.Signing.PublicKey, data, keys.Signing.Sign(data))) throw new CryptographicException("signature check failed");
    }

    /// Removes both keys (for "reset this PC").
    public static void Delete()
    {
        foreach (var provider in new[] { CngProvider.MicrosoftPlatformCryptoProvider, CngProvider.MicrosoftSoftwareKeyStorageProvider })
            foreach (var name in new[] { AgreementName, SigningName })
                if (CngKey.Exists(name, provider)) CngKey.Open(name, provider).Delete();
    }

    private static byte[] PublicRaw(CngKey key) =>
        P256.Raw(ECDiffieHellman.Create(ECParametersFrom(key)).ExportParameters(false));

    private static ECParameters ECParametersFrom(CngKey key)
    {
        // EccPublicBlob: magic (4) ‖ length (4) ‖ X ‖ Y.
        var blob = key.Export(CngKeyBlobFormat.EccPublicBlob);
        var len = BitConverter.ToInt32(blob, 4);
        return new ECParameters { Curve = P256.Curve, Q = new ECPoint { X = blob[8..(8 + len)], Y = blob[(8 + len)..(8 + 2 * len)] } };
    }

    /// ECDH with a CNG key. The TPM provider only agrees with public keys imported into
    /// the TPM provider itself, which .NET doesn't do, so this calls NCrypt directly:
    /// import the peer's point, NCryptSecretAgreement, then the raw secret ("TRUNCATE").
    private sealed class CngAgreementKey(CngKey key) : IAgreementKey
    {
        public byte[] PublicKey { get; } = PublicRaw(key);

        public byte[] SharedSecret(byte[] peer)
        {
            var q = P256.FromRaw(peer).Q;
            // BCRYPT_ECCKEY_BLOB: BCRYPT_ECDH_PUBLIC_P256_MAGIC ("ECK1"), cbKey = 32, X, Y.
            var blob = new byte[8 + 64];
            BitConverter.GetBytes(0x314B4345).CopyTo(blob, 0);
            BitConverter.GetBytes(32).CopyTo(blob, 4);
            q.X!.CopyTo(blob, 8);
            q.Y!.CopyTo(blob, 40);

            Check(NCrypt.NCryptOpenStorageProvider(out var provider, key.Provider!.Provider, 0));
            using (provider)
            {
                Check(NCrypt.NCryptImportKey(provider, IntPtr.Zero, "ECCPUBLICBLOB", IntPtr.Zero, out var peerKey, blob, blob.Length, 0));
                using (peerKey)
                {
                    Check(NCrypt.NCryptSecretAgreement(key.Handle, peerKey, out var secret, 0));
                    using (secret)
                    {
                        Check(NCrypt.NCryptDeriveKey(secret, "TRUNCATE", IntPtr.Zero, null, 0, out var size, 0));
                        var raw = new byte[size];
                        Check(NCrypt.NCryptDeriveKey(secret, "TRUNCATE", IntPtr.Zero, raw, raw.Length, out size, 0));
                        // CNG returns the raw secret little-endian; the protocol uses the big-endian x coordinate.
                        Array.Reverse(raw, 0, size);
                        return raw[..size];
                    }
                }
            }
        }

        private static void Check(int status)
        {
            if (status != 0) throw new CryptographicException(status);
        }
    }

    private static class NCrypt
    {
        [System.Runtime.InteropServices.DllImport("ncrypt.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        public static extern int NCryptOpenStorageProvider(out Microsoft.Win32.SafeHandles.SafeNCryptProviderHandle provider, string providerName, int flags);

        [System.Runtime.InteropServices.DllImport("ncrypt.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        public static extern int NCryptImportKey(Microsoft.Win32.SafeHandles.SafeNCryptProviderHandle provider, IntPtr importKey, string blobType,
            IntPtr parameterList, out Microsoft.Win32.SafeHandles.SafeNCryptKeyHandle key, byte[] data, int dataSize, int flags);

        [System.Runtime.InteropServices.DllImport("ncrypt.dll")]
        public static extern int NCryptSecretAgreement(Microsoft.Win32.SafeHandles.SafeNCryptKeyHandle privateKey,
            Microsoft.Win32.SafeHandles.SafeNCryptKeyHandle publicKey, out Microsoft.Win32.SafeHandles.SafeNCryptSecretHandle secret, int flags);

        [System.Runtime.InteropServices.DllImport("ncrypt.dll", CharSet = System.Runtime.InteropServices.CharSet.Unicode)]
        public static extern int NCryptDeriveKey(Microsoft.Win32.SafeHandles.SafeNCryptSecretHandle secret, string kdf, IntPtr parameterList,
            byte[]? derivedKey, int derivedKeySize, out int result, int flags);
    }

    private sealed class CngSigningKey(CngKey key) : ISigningKey
    {
        private readonly ECDsaCng _ecdsa = new(key);
        public byte[] PublicKey { get; } = PublicRaw(key);
        public byte[] Sign(byte[] data) =>
            _ecdsa.SignData(data, HashAlgorithmName.SHA256, DSASignatureFormat.IeeeP1363FixedFieldConcatenation);
    }
}
