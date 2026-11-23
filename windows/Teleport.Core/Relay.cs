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

    /// `hint: "file"` for large files: an iPhone gets a Live Activity instead of a notification.
    public async Task SendAsync(Envelope env, Peer to, CancellationToken ct = default, string? hint = null)
    {
        // Computers are reached through their mailbox; phones by push.
        object recipient = to.HasMailbox
            ? (object)new { platform = to.Platform, mailbox = to.Mailbox }
            : to.Fcm is { Length: > 0 } fcm
                ? new { platform = to.Platform, fcm, la = to.Platform == "ios" && !string.IsNullOrEmpty(to.La) ? to.La : null }
                : throw new RelayException(0, $"{to.Name} has no push address yet.");
        var json = hint is null
            ? $$"""{"to":{{Wire.Serialize(recipient)}},"env":{{env.ToJson()}}}"""
            : $$"""{"to":{{Wire.Serialize(recipient)}},"env":{{env.ToJson()}},"hint":"{{hint}}"}""";
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

    // ---------- large blobs (SPEC.md "Large blobs") ----------

    public sealed record Upload(string Id, string UploadId)
    {
        public string Path => $"v1/blob/upload/{Id}/{Uri.EscapeDataString(UploadId)}";
    }

    public async Task<Upload> StartUploadAsync(CancellationToken ct = default)
    {
        var body = JsonNode.Parse(await CallAsync(Request(HttpMethod.Post, "v1/blob/upload"), ct))!;
        return new Upload(body["id"]!.GetValue<string>(), body["upload"]!.GetValue<string>());
    }

    /// Uploads one part (1-based); returns its etag.
    public async Task<string> UploadPartAsync(Upload u, int part, ReadOnlyMemory<byte> bytes, CancellationToken ct = default)
    {
        var r = Request(HttpMethod.Put, $"{u.Path}/{part}");
        r.Content = new ReadOnlyMemoryContent(bytes);
        r.Content.Headers.ContentType = new MediaTypeHeaderValue("application/octet-stream");
        return JsonNode.Parse(await CallAsync(r, ct))!["etag"]!.GetValue<string>();
    }

    public async Task CompleteUploadAsync(Upload u, IReadOnlyList<string> etags, CancellationToken ct = default)
    {
        var parts = etags.Select((etag, i) => new { part = i + 1, etag });
        var r = Request(HttpMethod.Post, $"{u.Path}/complete");
        r.Content = new StringContent(Wire.Serialize(new { parts }), Encoding.UTF8, "application/json");
        await CallAsync(r, ct);
    }

    public async Task AbortUploadAsync(Upload u)
    {
        try { await CallAsync(Request(HttpMethod.Delete, u.Path), CancellationToken.None); } catch (Exception) { }
    }

    /// Streams a blob into `output` (no 250 MB in memory), reporting bytes so far and the total.
    public async Task DownloadBlobAsync(string id, Stream output, Action<long, long>? progress = null, CancellationToken ct = default)
    {
        using var res = await _http.SendAsync(Request(HttpMethod.Get, $"v1/blob/{id}"), HttpCompletionOption.ResponseHeadersRead, ct);
        if (!res.IsSuccessStatusCode) throw new RelayException((int)res.StatusCode, $"Relay error {(int)res.StatusCode}");
        var total = res.Content.Headers.ContentLength ?? 0;
        await using var input = await res.Content.ReadAsStreamAsync(ct);
        var buffer = new byte[256 * 1024];
        long done = 0;
        int n;
        while ((n = await input.ReadAsync(buffer, ct)) > 0)
        {
            await output.WriteAsync(buffer.AsMemory(0, n), ct);
            done += n;
            progress?.Invoke(done, total);
        }
    }

    public async Task DeleteBlobAsync(string id, CancellationToken ct = default) => await CallAsync(Request(HttpMethod.Delete, $"v1/blob/{id}"), ct);

    /// WebSocket URL for this computer's mailbox connection.
    public Uri MailboxConnectUri(string id) =>
        new(new Uri(_base.ToString().Replace("https://", "wss://").Replace("http://", "ws://")), $"v1/mailbox/{id}/connect");

    public string Authorization => $"Bearer {config.RelayKey}";
}
