using System.Net;
using System.Net.Http.Headers;
using System.Text;
using System.Text.Json;
using System.Text.Json.Nodes;

namespace Teleport.Core;

public sealed record RelayConfig(string RelayUrl, string RelayKey)
{
    public static RelayConfig Load(string path) => Wire.Deserialize<RelayConfig>(File.ReadAllText(path));
}

public class RelayException(int status, string message) : Exception(message) { public int Status { get; } = status; }
/// 410: the peer's push token is dead.
public sealed class PeerGoneException() : RelayException(410, "That device's push address expired. Open Teleport there, or pair again.");
/// 503: the computer isn't connected to its mailbox.
public sealed class OfflineException() : RelayException(503, "That device is offline.");

/// The Cloudflare relay (SPEC.md "Relay API").
public sealed class RelayClient(RelayConfig config, HttpClient? http = null)
{
    private readonly HttpClient _http = http ?? new HttpClient { Timeout = TimeSpan.FromSeconds(30) };
    private readonly Uri _base = new(config.RelayUrl.TrimEnd('/') + "/");

    public RelayConfig Config => config;

    private HttpRequestMessage Request(HttpMethod method, string path)
    {
        var r = new HttpRequestMessage(method, new Uri(_base, path));
        r.Headers.Authorization = new AuthenticationHeaderValue("Bearer", config.RelayKey);
        return r;
    }

    private async Task<byte[]> CallAsync(HttpRequestMessage r, CancellationToken ct)
    {
        using var res = await _http.SendAsync(r, ct);
        var body = await res.Content.ReadAsByteArrayAsync(ct);
        if (res.StatusCode == HttpStatusCode.Gone) throw new PeerGoneException();
        if (res.StatusCode == HttpStatusCode.ServiceUnavailable) throw new OfflineException();
        if (!res.IsSuccessStatusCode)
        {
            var reason = Encoding.UTF8.GetString(body);
            try { reason = JsonNode.Parse(reason)?["error"]?.GetValue<string>() ?? reason; } catch (JsonException) { }
            throw new RelayException((int)res.StatusCode, $"Relay error {(int)res.StatusCode}: {reason}");
        }
        return body;
    }

    public async Task SendAsync(Envelope env, Peer to, CancellationToken ct = default)
    {
        // Computers are reached through their mailbox; phones by push.
        object recipient = to.HasMailbox
            ? (object)new { platform = to.Platform, mailbox = to.Mailbox }
            : to.Fcm is { Length: > 0 } fcm
                ? new { platform = to.Platform, fcm, la = to.Platform == "ios" ? to.La : null }
                : throw new RelayException(0, $"{to.Name} has no push address yet.");
        var json = $$"""{"to":{{Wire.Serialize(recipient)}},"env":{{env.ToJson()}}}""";
        var r = Request(HttpMethod.Post, "v1/send");
        r.Content = new StringContent(json, Encoding.UTF8, "application/json");
        await CallAsync(r, ct);
    }

    public async Task<string> PutBlobAsync(byte[] ciphertext, CancellationToken ct = default)
    {
        var r = Request(HttpMethod.Put, "v1/blob");
        r.Content = new ByteArrayContent(ciphertext);
        r.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        var body = await CallAsync(r, ct);
        return JsonNode.Parse(body)!["id"]!.GetValue<string>();
    }

    public Task<byte[]> GetBlobAsync(string id, CancellationToken ct = default) => CallAsync(Request(HttpMethod.Get, $"v1/blob/{id}"), ct);

    public async Task DeleteBlobAsync(string id, CancellationToken ct = default) => await CallAsync(Request(HttpMethod.Delete, $"v1/blob/{id}"), ct);

    /// WebSocket URL for this computer's mailbox connection.
    public Uri MailboxConnectUri(string id) =>
        new(new Uri(_base.ToString().Replace("https://", "wss://").Replace("http://", "ws://")), $"v1/mailbox/{id}/connect");

    public string Authorization => $"Bearer {config.RelayKey}";
}
