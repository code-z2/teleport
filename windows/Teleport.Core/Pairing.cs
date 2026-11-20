using System.Text;
using System.Text.Json;

namespace Teleport.Core;

/// QR payload: `teleport2:<b64u(JSON)>` (SPEC.md "v2 additions"). `ps`, the one-time
/// pairing secret, is only ever in the QR code, never sent over the network.
public sealed record PairingCard(
    string Name, string Platform, string Ka, string Ks,
    string? Fcm = null, string? La = null, string? Mailbox = null, string? Ps = null, int V = 2)
{
    public const string Prefix = "teleport2:";
    public static readonly string[] Platforms = ["ios", "android", "mac", "windows"];

    /// The card as sent inside `pair` / `pair-ok`: no secret.
    public string Json() => Wire.Serialize(this with { Ps = null });

    /// The QR payload, including the secret.
    public string Encoded() => Prefix + B64.Url(Encoding.UTF8.GetBytes(Wire.Serialize(this)));

    public static PairingCard Decode(string s)
    {
        if (!s.StartsWith(Prefix, StringComparison.Ordinal)) throw new OpenException("encoding");
        PairingCard card;
        try { card = Wire.Deserialize<PairingCard>(Encoding.UTF8.GetString(B64.FromUrl(s[Prefix.Length..]))); }
        catch (Exception e) when (e is JsonException or FormatException) { throw new OpenException("encoding"); }
        if (card.V != 2 || !Platforms.Contains(card.Platform) ||
            !B64.TryFromUrl(card.Ka, out var ka) || ka.Length != 65 ||
            !B64.TryFromUrl(card.Ks, out var ks) || ks.Length != 65)
            throw new OpenException("encoding");
        return card;
    }
}

/// A paired device. Public keys and push addresses only, nothing secret.
public sealed record Peer(
    string Name, string Platform, string Ka, string Ks,
    string? Fcm = null, string? La = null, string? Mailbox = null, long PairedAt = 0)
{
    public byte[] KaBytes => B64.FromUrl(Ka);
    public byte[] KsBytes => B64.FromUrl(Ks);

    /// `fp(ks)`: the device's identity, and the `from` of every envelope it sends.
    public string Id => TeleportCrypto.Fingerprint(KsBytes);

    /// Reached through a relay mailbox (a Mac or a Windows PC) rather than push.
    public bool HasMailbox => Mailbox is not null && Platform is "mac" or "windows";

    public static Peer From(PairingCard c) =>
        new(c.Name, c.Platform, c.Ka, c.Ks, c.Fcm, c.La, c.Mailbox, DateTimeOffset.UtcNow.ToUnixTimeMilliseconds());
}

/// A device that scanned our QR code and is waiting for the user to click Allow.
public sealed record PairRequest(string Id, string CardJson, string Name, string Platform, long Expires);
