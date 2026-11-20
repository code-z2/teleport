using System.Windows;
using System.Windows.Media.Imaging;
using System.Windows.Threading;
using Teleport.Core;

namespace Teleport.Windows;

/// Everything the tray icon and panel show and do. Lives on the UI thread; background
/// work (relay, mailbox) marshals back through the dispatcher.
public sealed class AppModel : IAsyncDisposable
{
    private readonly Dispatcher _ui = Dispatcher.CurrentDispatcher;
    public TeleportClient? Teleport { get; }
    public MailboxConnection? Connection { get; }
    public string? LoadError { get; }
    public bool HardwareKeys { get; }
    public KeepAwake KeepAwake { get; } = new();

    public string Name { get; private set; }
    public List<Peer> Peers { get; private set; } = [];
    public List<PairRequest> Requests { get; private set; } = [];
    public IReadOnlyList<string> Browsers { get; private set; } = [];
    public string? PairingCode { get; private set; }
    public string? Activity { get; private set; }

    /// Something visible changed: the panel and tray redraw.
    public event Action? Changed;
    /// A notification for the tray balloon: title, text, and what clicking it opens.
    public event Action<string, string, Action?>? Notify;

    public AppModel()
    {
        Name = Environment.MachineName;
        try
        {
            var store = new Store(Path.Combine(Log.Folder, "store.json"));
            var keys = TpmKeys.LoadOrCreate();
            HardwareKeys = keys.Hardware;
            if (!keys.Hardware) Log.Write($"TPM unavailable, using software keys: {keys.TpmProblem}");
            var relay = new RelayClient(RelayConfig.Load(Path.Combine(AppContext.BaseDirectory, "relay.json")));
            Teleport = new TeleportClient(keys.Agreement, keys.Signing, store, relay);
            Name = store.DeviceName ?? FriendlyMachineName();
            store.DeviceName ??= Name;

            Connection = new MailboxConnection(Teleport, () => new FileServer.Options(
                Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), store.ShowHiddenFiles))
            {
                Thumbnailer = Thumbnails.JpegAsync,
                Log = Log.Write,
            };
            Connection.StateChanged += () => _ui.InvokeAsync(Raise);
            Connection.BrowsersChanged += names => _ui.InvokeAsync(() => { Browsers = names; Raise(); });
            Connection.Envelope += json => _ui.InvokeAsync(() => ReceiveAsync(json)).Task.Unwrap();
            store.Changed += () => _ui.InvokeAsync(Reload);
            KeepAwake.Enabled = store.KeepAwakeOnPower;
            KeepAwake.Changed += Raise;

            // Wake, sleep and network changes: reconnect straight away instead of waiting out the backoff.
            Microsoft.Win32.SystemEvents.PowerModeChanged += (_, e) =>
            {
                if (e.Mode == Microsoft.Win32.PowerModes.Resume) Connection.ReconnectNow();
            };
            System.Net.NetworkInformation.NetworkChange.NetworkAvailabilityChanged += (_, e) =>
            {
                if (e.IsAvailable) Connection.ReconnectNow();
            };
            // A code is single-use and lasts 10 minutes: while one is on screen, swap in a
            // fresh one as soon as it's spent or expired, so the QR shown always works.
            var refresh = new DispatcherTimer { Interval = TimeSpan.FromSeconds(1) };
            refresh.Tick += (_, _) =>
            {
                if (PairingCode is not null && store.CurrentPairingSecret() is null) { PairingCode = Teleport.QrCode(Name); Raise(); }
            };
            refresh.Start();
            var idle = new DispatcherTimer { Interval = TimeSpan.FromSeconds(30) };
            idle.Tick += (_, _) => Connection.CloseIdleSessions();
            idle.Start();

            Connection.Start();
            Log.Write($"started as {Teleport.MyId} ({(HardwareKeys ? "TPM" : "software")} keys)");
        }
        catch (Exception e)
        {
            LoadError = $"Couldn't start Teleport: {e.Message}";
            Log.Write(LoadError + "\n" + e);
        }
        Reload();
    }

    /// "Peso's PC" style names read better than DESKTOP-AB12CD; the user can rename.
    private static string FriendlyMachineName()
    {
        var host = Environment.MachineName.Replace('_', ' ');
        return host.StartsWith("DESKTOP-", StringComparison.OrdinalIgnoreCase) ? $"{Environment.UserName}'s PC" : host;
    }

    private void Raise() => Changed?.Invoke();

    public void Reload()
    {
        if (Teleport is { } t)
        {
            Peers = t.Store.SortedPeers;
            Requests = [.. t.Store.PairRequests.Values.OrderBy(r => r.Expires)];
        }
        Raise();
    }

    public bool IsOnline => Connection?.State == MailboxConnection.Status.Online;

    public string StatusText => Connection switch
    {
        null => "Not running",
        { State: MailboxConnection.Status.Online } => "Online. Your phones can reach this PC",
        { State: MailboxConnection.Status.Connecting } => "Connecting…",
        { OfflineReason: { } reason } => $"Offline: {reason}",
        _ => "Offline",
    };

    private void Say(string text) { Activity = text; Log.Write(text); Raise(); }

    // ---------- settings ----------

    public bool ShowHiddenFiles
    {
        get => Teleport?.Store.ShowHiddenFiles ?? false;
        set { if (Teleport is { } t) t.Store.ShowHiddenFiles = value; }
    }

    public bool KeepAwakeOnPower
    {
        get => Teleport?.Store.KeepAwakeOnPower ?? true;
        set { if (Teleport is { } t) t.Store.KeepAwakeOnPower = value; KeepAwake.Enabled = value; }
    }

    public bool SaveImages
    {
        get => Teleport?.Store.SaveImages ?? true;
        set { if (Teleport is { } t) t.Store.SaveImages = value; }
    }

    public async Task RenameAsync(string name)
    {
        name = name.Trim();
        if (Teleport is not { } t || name.Length == 0 || name == Name) return;
        Name = name;
        t.Store.DeviceName = name;
        var failed = await t.AnnounceAsync(name);
        Say(failed == 0 ? $"Renamed to {name}." : $"Renamed. {failed} device(s) will update when they're reachable.");
    }

    // ---------- pairing ----------

    public void ShowPairingCode()
    {
        if (Teleport is not { } t) return;
        PairingCode = t.QrCode(Name);
        Raise();
    }

    public void HidePairingCode() { PairingCode = null; Raise(); }

    public async Task PairWithCodeAsync(string code)
    {
        if (Teleport is not { } t) return;
        try
        {
            var peer = await t.ScanAsync(code, Name);
            Say($"Sent a pairing request to {peer.Name}. Tap Allow there.");
        }
        catch (Exception e) { Say(e.Message); }
    }

    public async Task AllowAsync(PairRequest request)
    {
        if (Teleport is not { } t) return;
        try
        {
            var peer = await t.AllowAsync(request.Id, Name);
            PairingCode = null;
            Say($"Paired with {peer.Name}.");
        }
        catch (Exception e) { Say($"Couldn't finish pairing with {request.Name}: {e.Message}"); Log.Write(e.ToString()); }
        Reload();
    }

    public void Deny(PairRequest request) { Teleport?.Deny(request.Id); Reload(); }

    public void Remove(Peer peer) { Teleport?.Store.RemovePeer(peer.Id); Reload(); }

    // ---------- receive ----------

    private async Task ReceiveAsync(string json)
    {
        if (Teleport is not { } t) return;
        Received received;
        try { received = await t.ReceiveAsync(json); }
        catch (OpenException e) when (e.Code == "replay") { return; }
        catch (OpenException e) when (e.Code == "proof")
        {
            Log.Write("pairing request with a used or expired code");
            Notify?.Invoke("Pairing code already used", "Scan the new code shown in Teleport.", () => { if (PairingCode is null) ShowPairingCode(); OpenPanel?.Invoke(); });
            return;
        }
        catch (Exception e) { Log.Write($"receive failed: {e.Message}"); return; }

        switch (received)
        {
            case Received.ClipReceived { Clip: Clip.Text text, From: var from }:
                SetClipboardText(text.Value);
                Notify?.Invoke($"From {from.Name}", Preview(text.Value) + "\nCopied to the clipboard.", null);
                break;
            case Received.ClipReceived { Clip: Clip.Bytes bytes, From: var from } when bytes.Mime.StartsWith("image/"):
                var saved = SaveImages ? SaveToDownloads(bytes.Data, bytes.Mime, from.Name) : null;
                SetClipboardImage(bytes.Data);
                Notify?.Invoke($"Image from {from.Name}", saved is null ? "Copied to the clipboard." : "Copied, and saved to Downloads\\Teleport.",
                    saved is null ? null : () => System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{saved}\""));
                break;
            case Received.ClipReceived { Clip: Clip.Bytes other, From: var from }:
                var file = SaveToDownloads(other.Data, other.Mime, from.Name);
                Notify?.Invoke($"File from {from.Name}", "Saved to Downloads\\Teleport.",
                    file is null ? null : () => System.Diagnostics.Process.Start("explorer.exe", $"/select,\"{file}\""));
                break;
            case Received.PairRequested { Request: var r }:
                Log.Write($"pairing request from {r.Name} ({r.Platform})");
                Notify?.Invoke("Pairing request", $"{r.Name} wants to pair. Open Teleport to allow it.", () => OpenPanel?.Invoke());
                break;
            case Received.Paired { Peer: var p }:
                Log.Write($"paired with {p.Name} ({p.Platform})");
                PairingCode = null;
                Notify?.Invoke("Paired", $"{p.Name} is ready.", null);
                break;
            case Received.Declined { Peer: var p }:
                Log.Write($"{p.Name} declined pairing");
                Notify?.Invoke($"{p.Name} declined", "Pairing wasn't allowed.", null);
                break;
            case Received.PeerUpdated:
                break;
        }
        Reload();
    }

    public void Toast(string title, string text) => Notify?.Invoke(title, text, null);

    /// Set by the tray: shows the panel (used by notification clicks).
    public Action? OpenPanel { get; set; }

    private static string Preview(string text) => text.Length > 120 ? text[..117] + "…" : text;

    private static void SetClipboardText(string text)
    {
        for (var i = 0; i < 5; i++)
        {
            // Another app can hold the clipboard open for a moment.
            try { Clipboard.SetText(text); return; } catch (System.Runtime.InteropServices.COMException) { Thread.Sleep(50); }
        }
    }

    private static void SetClipboardImage(byte[] data)
    {
        try
        {
            var image = new BitmapImage();
            image.BeginInit();
            image.CacheOption = BitmapCacheOption.OnLoad;
            image.StreamSource = new MemoryStream(data);
            image.EndInit();
            image.Freeze();
            Clipboard.SetImage(image);
        }
        catch (Exception e) { Log.Write($"clipboard image: {e.Message}"); }
    }

    private static string? SaveToDownloads(byte[] data, string mime, string from)
    {
        try
        {
            var downloads = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), "Downloads", "Teleport");
            Directory.CreateDirectory(downloads);
            var ext = mime switch
            {
                "image/png" => ".png", "image/jpeg" => ".jpg", "image/gif" => ".gif", "image/heic" => ".heic",
                "image/webp" => ".webp", _ => ".bin",
            };
            var safe = string.Concat(from.Split(Path.GetInvalidFileNameChars()));
            var path = Path.Combine(downloads, FileServer.UniqueName($"{safe} {DateTime.Now:yyyy-MM-dd HH.mm.ss}{ext}", downloads));
            File.WriteAllBytes(path, data);
            return path;
        }
        catch (Exception e) { Log.Write($"save image: {e.Message}"); return null; }
    }

    // ---------- send ----------

    /// What's on the clipboard: an image if there is one, otherwise text.
    public static Clip? ReadClipboard()
    {
        try
        {
            if (Clipboard.ContainsImage() && Clipboard.GetImage() is { } image)
            {
                var encoder = new PngBitmapEncoder();
                encoder.Frames.Add(BitmapFrame.Create(image));
                using var ms = new MemoryStream();
                encoder.Save(ms);
                return new Clip.Bytes(ms.ToArray(), "image/png");
            }
            if (Clipboard.ContainsFileDropList() && Clipboard.GetFileDropList() is { Count: > 0 } files)
                return ClipFromFile(files[0]!);
            if (Clipboard.ContainsText()) return new Clip.Text(Clipboard.GetText());
        }
        catch (System.Runtime.InteropServices.COMException) { }
        return null;
    }

    /// A file for Send To: images go as images, text files as text, anything else as a file.
    public static Clip? ClipFromFile(string path)
    {
        if (!File.Exists(path)) return null;
        var mime = Mime.ForName(path);
        if (mime.StartsWith("text/") && new FileInfo(path).Length < 1_000_000) return new Clip.Text(File.ReadAllText(path));
        return new Clip.Bytes(File.ReadAllBytes(path), mime);
    }

    public async Task SendAsync(Clip clip, Peer to)
    {
        if (Teleport is not { } t) return;
        Say($"Sending to {to.Name}…");
        try
        {
            await t.SendAsync(clip, to);
            Say($"Sent to {to.Name}.");
            Notify?.Invoke("Teleport", $"Sent to {to.Name}.", null);
        }
        catch (OfflineException) { Say($"{to.Name} is offline."); Notify?.Invoke("Couldn't send", $"{to.Name} is offline.", null); }
        catch (PeerGoneException e) { Say(e.Message); Notify?.Invoke("Couldn't send", e.Message, null); }
        catch (Exception e) { Say($"Couldn't send: {e.Message}"); Notify?.Invoke("Couldn't send", e.Message, null); }
    }

    public async ValueTask DisposeAsync()
    {
        KeepAwake.Dispose();
        if (Connection is not null) await Connection.DisposeAsync();
    }
}
