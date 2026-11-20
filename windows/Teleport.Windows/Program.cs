using System.IO.Pipes;
using System.Text;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Media;
using Teleport.Core;

namespace Teleport.Windows;

public static class Program
{
    private const string MutexName = @"Local\Teleport.Windows";
    private const string PipeName = "Teleport.Windows.Send";

    [STAThread]
    public static int Main(string[] args)
    {
        if (args is ["--selftest"]) return SelfTest();

        // One copy runs. A second launch (Send To, or opening it again) hands its request over.
        using var mutex = new Mutex(true, MutexName, out var first);
        if (!first)
        {
            ForwardToRunningCopy(args);
            return 0;
        }

        var app = new Application { ShutdownMode = ShutdownMode.OnExplicitShutdown };
#pragma warning disable WPF0001  // Fluent theme (.NET 9)
        app.ThemeMode = ThemeMode.System;
#pragma warning restore WPF0001
        AppModel? model = null;
        Tray? tray = null;
        app.Startup += (_, _) =>
        {
            model = new AppModel();
            tray = new Tray(model);
            if (!SendToMenu.Installed) { try { SendToMenu.Install(); } catch (Exception e) { Log.Write($"send-to: {e.Message}"); } }
            ListenForSends(model);
            if (args.FirstOrDefault() == "--send") HandleSend(model, [.. args.Skip(1)]);
            else if (args.FirstOrDefault() != "--background") tray.ShowPanel();
        };
        app.Exit += (_, _) =>
        {
            tray?.Dispose();
            model?.DisposeAsync().AsTask().Wait(TimeSpan.FromSeconds(2));
        };
        app.DispatcherUnhandledException += (_, e) => { Log.Write($"unhandled: {e.Exception}"); e.Handled = true; };
        return app.Run();
    }

    private static int SelfTest()
    {
        // A GUI app has no console: report through a file (tools/win reads it).
        var report = Path.Combine(Path.GetTempPath(), "teleport-selftest.txt");
        try
        {
            var keys = TpmKeys.LoadOrCreate();
            File.WriteAllText(report, $"ok hardware={keys.Hardware} id={TeleportCrypto.Fingerprint(keys.Signing.PublicKey)} tpm={keys.TpmProblem}");
            return 0;
        }
        catch (Exception e)
        {
            File.WriteAllText(report, $"failed {e}");
            return 1;
        }
    }

    // ---------- single instance ----------

    private static void ForwardToRunningCopy(string[] args)
    {
        try
        {
            using var pipe = new NamedPipeClientStream(".", PipeName, PipeDirection.Out);
            pipe.Connect(3000);
            var payload = Encoding.UTF8.GetBytes(string.Join('\n', args.Length == 0 ? ["--open"] : args));
            pipe.Write(payload);
        }
        catch (Exception e) { Log.Write($"forward: {e.Message}"); }
    }

    private static void ListenForSends(AppModel model)
    {
        var ui = Application.Current.Dispatcher;
        Task.Run(async () =>
        {
            while (true)
            {
                try
                {
                    await using var server = new NamedPipeServerStream(PipeName, PipeDirection.In, 1, PipeTransmissionMode.Byte, PipeOptions.Asynchronous);
                    await server.WaitForConnectionAsync();
                    using var reader = new StreamReader(server, Encoding.UTF8);
                    var args = (await reader.ReadToEndAsync()).Split('\n', StringSplitOptions.RemoveEmptyEntries);
                    await ui.InvokeAsync(() =>
                    {
                        if (args.FirstOrDefault() == "--send") HandleSend(model, [.. args.Skip(1)]);
                        else model.OpenPanel?.Invoke();
                    });
                }
                catch (Exception e) { Log.Write($"pipe: {e.Message}"); await Task.Delay(1000); }
            }
        });
    }

    // ---------- Send To ----------

    /// Files from Explorer's "Send to ▸ Teleport": pick a device (if several), then send each.
    private static void HandleSend(AppModel model, string[] files)
    {
        var clips = files.Select(f => (file: f, clip: AppModel.ClipFromFile(f))).Where(x => x.clip is not null).ToList();
        if (clips.Count == 0) { model.Toast("Nothing to send", "Teleport can send files up to 10 MB."); return; }
        var tooBig = clips.Where(x => x.clip is Clip.Bytes b && b.Data.Length + 16 > TeleportClient.MaxBlobBytes).ToList();
        if (tooBig.Count > 0) { model.Toast("Too large to teleport", $"{Path.GetFileName(tooBig[0].file)} is over 10 MB."); return; }

        void SendAll(Peer peer)
        {
            _ = Task.Run(async () =>
            {
                foreach (var (_, clip) in clips) await Application.Current.Dispatcher.InvokeAsync(() => model.SendAsync(clip!, peer)).Task.Unwrap();
            });
        }

        if (model.Peers.Count == 0) { model.Toast("No devices yet", "Pair a phone first."); model.OpenPanel?.Invoke(); return; }
        if (model.Peers.Count == 1) { SendAll(model.Peers[0]); return; }
        var title = clips.Count == 1 ? $"Send \"{Path.GetFileName(clips[0].file)}\" to…" : $"Send {clips.Count} files to…";
        DevicePicker.Show(model.Peers, title, SendAll);
    }
}

/// "Send to…": a small Fluent window listing devices by name, opened at the pointer.
public static class DevicePicker
{
    public static void Show(IReadOnlyList<Peer> peers, string title, Action<Peer> chosen)
    {
        var window = new Window
        {
            Title = "Teleport", Width = 320, SizeToContent = SizeToContent.Height, WindowStyle = WindowStyle.ToolWindow,
            ResizeMode = ResizeMode.NoResize, Topmost = true, ShowInTaskbar = false, WindowStartupLocation = WindowStartupLocation.Manual,
        };
        var stack = new StackPanel { Margin = new Thickness(16) };
        stack.Children.Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 0, 0, 10) });
        foreach (var peer in peers)
        {
            var row = new StackPanel { Orientation = Orientation.Horizontal };
            row.Children.Add(new TextBlock
            {
                Text = peer.Platform is "ios" or "android" ? "" : peer.Platform == "mac" ? "" : "",
                FontFamily = new FontFamily("Segoe Fluent Icons"), FontSize = 16, VerticalAlignment = VerticalAlignment.Center,
                Margin = new Thickness(0, 0, 10, 0),
            });
            row.Children.Add(new TextBlock { Text = peer.Name, VerticalAlignment = VerticalAlignment.Center });
            var button = new Button { Content = row, HorizontalContentAlignment = HorizontalAlignment.Left, Padding = new Thickness(12, 8, 12, 8), Margin = new Thickness(0, 2, 0, 2) };
            button.Click += (_, _) => { window.Close(); chosen(peer); };
            stack.Children.Add(button);
        }
        var cancel = new Button { Content = "Cancel", HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 8, 0, 0), Padding = new Thickness(12, 5, 12, 6) };
        cancel.Click += (_, _) => window.Close();
        stack.Children.Add(cancel);
        window.Content = stack;
        var pos = System.Windows.Forms.Cursor.Position;
        var dpi = VisualTreeHelper.GetDpi(new System.Windows.Controls.Control());
        window.Left = pos.X / dpi.DpiScaleX - 160;
        window.Top = pos.Y / dpi.DpiScaleY - 40;
        window.Show();
        window.Activate();
    }
}
