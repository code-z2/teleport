using System.Net;
using System.Text;
using System.Text.Json.Nodes;
using Teleport.Core;
using Xunit;

namespace Teleport.Core.Tests;

/// The whole pairing exchange between a Windows PC and a phone, with the relay faked:
/// every /v1/send is captured so the test can deliver it to the other side.
public class PairingFlowTests : IDisposable
{
    private sealed class FakeRelay : HttpMessageHandler
    {
        public readonly List<JsonNode> Sent = [];
        protected override async Task<HttpResponseMessage> SendAsync(HttpRequestMessage request, CancellationToken ct)
        {
            var body = request.Content is null ? "" : await request.Content.ReadAsStringAsync(ct);
            if (request.RequestUri!.AbsolutePath.EndsWith("/v1/send"))
            {
                var json = JsonNode.Parse(body)!;
                // Like the real relay: an envelope has exactly the nine wire fields.
                var fields = json["env"]!.AsObject().Select(kv => kv.Key).Order().ToArray();
                if (!fields.SequenceEqual(new[] { "ct", "epk", "from", "id", "k", "n", "sig", "ts", "v" }))
                    return new HttpResponseMessage(HttpStatusCode.BadRequest) { Content = new StringContent($$"""{"ok":false,"error":"unexpected env fields: {{string.Join(",", fields)}}"}""") };
                Sent.Add(json);
            }
            return new HttpResponseMessage(HttpStatusCode.OK) { Content = new StringContent("""{"ok":true}""") };
        }
    }

    private readonly string _dir = Path.Combine(Path.GetTempPath(), "teleport-pair-" + Guid.NewGuid().ToString("N"));
    private readonly FakeRelay _relay = new();

    private TeleportClient Device(string name) => new(new SoftwareAgreementKey(), new SoftwareSigningKey(),
        new Store(Path.Combine(_dir, name + ".json")),
        new RelayClient(new RelayConfig("https://relay.test", "k"), new HttpClient(_relay)));

    public void Dispose() { try { Directory.Delete(_dir, true); } catch { } }

    /// A phone's card as the phone would send it (an iOS card with push tokens).
    private static PairingCard PhoneCard(TeleportClient phone) =>
        new("Peso's iPhone", "ios", B64.Url(phone.Agreement.PublicKey), B64.Url(phone.Signing.PublicKey), Fcm: "fcm-token", La: "la-token");

    [Fact]
    public async Task PcShowsCodePhoneScansPcAllows()
    {
        var pc = Device("pc");
        var phone = Device("phone");
        var qr = pc.QrCode("Peso's PC");

        // The phone scans: its side is played by the same core, sending as an iOS device.
        var pcCard = PairingCard.Decode(qr);
        var pcPeer = Peer.From(pcCard);
        var myJson = PhoneCard(phone).Json();
        var body = TeleportCrypto.PairPlaintext(myJson, TeleportCrypto.PairProof(B64.FromUrl(pcCard.Ps!), myJson));
        var pair = TeleportCrypto.Seal(Kind.Pair, body, phone.Signing, pcPeer.KaBytes);
        Assert.True(pcPeer.HasMailbox);

        // The PC receives the request, then the user clicks Allow.
        var requested = Assert.IsType<Received.PairRequested>(await pc.ReceiveAsync(pair.ToJson()));
        Assert.Equal("Peso's iPhone", requested.Request.Name);
        var peer = await pc.AllowAsync(requested.Request.Id, "Peso's PC");

        Assert.Equal("Peso's iPhone", peer.Name);
        Assert.Single(pc.Store.Peers);
        Assert.Empty(pc.Store.PairRequests);

        // pair-ok went to the phone by push, and opens with the PC's QR key.
        var sent = Assert.Single(_relay.Sent);
        Assert.Equal("ios", sent["to"]!["platform"]!.GetValue<string>());
        Assert.Equal("fcm-token", sent["to"]!["fcm"]!.GetValue<string>());
        var ok = Envelope.Parse(sent["env"]!.ToJsonString());
        Assert.Equal(Kind.PairOk, ok.K);
        var card = Wire.Deserialize<PairingCard>(Encoding.UTF8.GetString(TeleportCrypto.Open(ok, phone.Agreement, pcPeer.KsBytes)));
        Assert.Equal("windows", card.Platform);
        Assert.Equal(pc.MyId, card.Mailbox);
    }

    [Fact]
    public async Task PcSendsToPairedComputerThroughMailbox()
    {
        var pc = Device("pc");
        var mac = new Peer("Mac", "mac", B64.Url(new SoftwareAgreementKey().PublicKey), B64.Url(new SoftwareSigningKey().PublicKey), Mailbox: "abcdefghijk");
        pc.Store.PutPeer(mac);
        await pc.SendAsync(new Clip.Text("hi"), mac);
        var to = Assert.Single(_relay.Sent)["to"]!;
        Assert.Equal("mac", to["platform"]!.GetValue<string>());
        Assert.Equal("abcdefghijk", to["mailbox"]!.GetValue<string>());
        Assert.Null(to["fcm"]);
    }
}
