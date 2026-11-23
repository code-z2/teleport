using Teleport.Core;
using Xunit;

namespace Teleport.Core.Tests;

public class MoveIntoPlaceTests
{
    [Fact]
    public void NeverReplacesAnExistingFile()
    {
        var dir = Directory.CreateTempSubdirectory("teleport-move-").FullName;
        try
        {
            File.WriteAllText(Path.Combine(dir, "report.pdf"), "original");
            var first = Path.Combine(dir, ".a.part"); File.WriteAllText(first, "first");
            var second = Path.Combine(dir, ".b.part"); File.WriteAllText(second, "second");

            Assert.Equal("report (2).pdf", FileServer.MoveIntoPlace(first, dir, "report.pdf"));
            Assert.Equal("report (3).pdf", FileServer.MoveIntoPlace(second, dir, "report.pdf"));

            Assert.Equal("original", File.ReadAllText(Path.Combine(dir, "report.pdf")));
            Assert.Equal("first", File.ReadAllText(Path.Combine(dir, "report (2).pdf")));
            Assert.Equal("second", File.ReadAllText(Path.Combine(dir, "report (3).pdf")));
        }
        finally { Directory.Delete(dir, true); }
    }

    [Fact]
    public async Task SameNameArrivingAtOnceKeepsBoth()
    {
        var dir = Directory.CreateTempSubdirectory("teleport-move-").FullName;
        try
        {
            var temps = Enumerable.Range(0, 8).Select(i =>
            {
                var t = Path.Combine(dir, $".{i}.part"); File.WriteAllText(t, $"copy {i}"); return t;
            }).ToList();
            var names = await Task.WhenAll(temps.Select(t => Task.Run(() => FileServer.MoveIntoPlace(t, dir, "report.pdf"))));

            Assert.Equal(8, names.Distinct().Count());
            var contents = names.Select(n => File.ReadAllText(Path.Combine(dir, n))).Order().ToList();
            Assert.Equal(Enumerable.Range(0, 8).Select(i => $"copy {i}").Order().ToList(), contents);
        }
        finally { Directory.Delete(dir, true); }
    }
}
