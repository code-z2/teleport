using System.Text.Json.Nodes;
using Teleport.Core;
using Xunit;
using static Teleport.Core.Tests.VectorTests;

namespace Teleport.Core.Tests;

/// protocol/vectors.json "chunked" (SPEC.md "Large blobs").
public class ChunkedBlobTests
{
    private static readonly JsonNode C = V["chunked"]!;
    private static readonly byte[] Key = B(C["key"]);
    private static readonly byte[] N = B(C["n"]);
    private static readonly int Chunk = C["c"]!.GetValue<int>();

    [Fact]
    public void SealMatchesAndOpens()
    {
        foreach (var v in C["cases"]!.AsArray())
        {
            var plain = B(v!["plaintext"]);
            Assert.Equal(S(v["ciphertext"]), B64.Url(ChunkedBlob.Seal(plain, Key, N, Chunk)));
            Assert.Equal(plain, ChunkedBlob.Open(B(v["ciphertext"]), plain.Length, Key, N, Chunk));
        }
    }

    [Fact]
    public void RejectsTruncationReorderingAndWrongSize()
    {
        var ct = B(C["cases"]![0]!["ciphertext"]);  // 25 bytes: 26 + 26 + 21
        Assert.Throws<OpenException>(() => ChunkedBlob.Open(ct[..52], 20, Key, N, Chunk));
        byte[] swapped = [.. ct[26..52], .. ct[..26], .. ct[52..]];
        Assert.Throws<OpenException>(() => ChunkedBlob.Open(swapped, 25, Key, N, Chunk));
        Assert.Throws<OpenException>(() => ChunkedBlob.Open(ct, 24, Key, N, Chunk));
    }

    [Fact]
    public void PointerOmitsAbsentFields()
    {
        Assert.DoesNotContain("\"c\"", Wire.Serialize(new BlobPointer("a", "image/png", 3, "k", "n")));
        var big = Wire.Deserialize<BlobPointer>("""{"id":"a","mime":"video/mp4","size":9,"key":"k","n":"n","c":4194304,"name":"Clip.mp4"}""");
        Assert.True(big.IsChunked);
        Assert.Equal("Clip.mp4", big.Name);
    }
}
