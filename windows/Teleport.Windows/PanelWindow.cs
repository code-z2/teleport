using System.Runtime.InteropServices;
using System.Windows;
using System.Windows.Controls;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using QRCoder;
using Teleport.Core;

namespace Teleport.Windows;

/// The flyout above the notification area: this PC, pairing, devices and settings.
/// The Windows counterpart of the Mac's menu bar panel, in the Windows 11 Fluent theme.
public sealed class PanelWindow : Window
{
    private readonly AppModel _model;
    private readonly StackPanel _root = new() { Margin = new Thickness(16) };
    private bool _renaming;

    public PanelWindow(AppModel model)
    {
        _model = model;
        Title = "Teleport";
        Width = 380;
        SizeToContent = SizeToContent.Height;
        WindowStyle = WindowStyle.None;
        ResizeMode = ResizeMode.NoResize;
        ShowInTaskbar = false;
        Topmost = true;
        Content = new ScrollViewer { Content = _root, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, MaxHeight = 720 };
        Deactivated += (_, _) => { if (!_renaming) Hide(); };
        PreviewKeyDown += (_, e) => { if (e.Key == Key.Escape) Hide(); };
        SourceInitialized += (_, _) => RoundCorners();
        model.Changed += () => { if (IsVisible) Build(); };
        Build();
    }

    // ---------- placement ----------

    public void ShowNearTray()
    {
        _model.Reload();
        Build();
        Show();
        UpdateLayout();
        // Bottom-right of the work area (above the taskbar), like Windows' own flyouts.
        var area = SystemParameters.WorkArea;
        Left = area.Right - ActualWidth - 12;
        Top = area.Bottom - ActualHeight - 12;
        Activate();
    }

    [DllImport("dwmapi.dll")]
    private static extern int DwmSetWindowAttribute(IntPtr hwnd, int attribute, ref int value, int size);

    private void RoundCorners()
    {
        var hwnd = new WindowInteropHelper(this).Handle;
        var round = 2;  // DWMWCP_ROUND
        DwmSetWindowAttribute(hwnd, 33, ref round, sizeof(int));  // DWMWA_WINDOW_CORNER_PREFERENCE
    }

    // ---------- content ----------

    private void Build()
    {
        _root.Children.Clear();
        Header();
        if (_model.LoadError is { } error) Add(Caption(error, Brushes.IndianRed));
        if (_model.Browsers.Count > 0)
        {
            // The icon in the icon font, the names in the normal font (one font for both turns names into symbols).
            var row = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 0, 0, 8) };
            var icon = Glyph("\uE8B7");
            icon.Foreground = Accent;
            icon.Margin = new Thickness(0, 0, 8, 0);
            row.Children.Add(icon);
            var text = Caption($"{Join(_model.Browsers)} {(_model.Browsers.Count == 1 ? "is" : "are")} browsing your files", Accent);
            text.FontSize = 13;
            text.VerticalAlignment = VerticalAlignment.Center;
            row.Children.Add(text);
            Add(row);
        }
        if (_model.Requests.Count > 0) Requests();
        if (_model.PairingCode is { } code) Pairing(code);
        Devices();
        Separator();
        Settings();
        if (_model.Activity is { } activity) Add(Caption(activity, Secondary));
        Separator();
        Footer();
    }

    private void Header()
    {
        var row = new DockPanel { Margin = new Thickness(0, 0, 0, 12) };
        var dot = new System.Windows.Shapes.Ellipse
        {
            Width = 10, Height = 10, Margin = new Thickness(0, 0, 10, 0), VerticalAlignment = VerticalAlignment.Center,
            Fill = _model.IsOnline ? Brushes.MediumSeaGreen : _model.Connection?.State == MailboxConnection.Status.Connecting ? Brushes.Orange : Brushes.IndianRed,
        };
        row.Children.Add(dot);
        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = "Teleport", FontSize = 18, FontWeight = FontWeights.SemiBold });
        text.Children.Add(Caption(_model.StatusText, Secondary));
        row.Children.Add(text);
        Add(row);
    }

    private void Requests()
    {
        Section("Pairing requests");
        foreach (var r in _model.Requests)
        {
            var card = Card();
            var stack = new StackPanel();
            stack.Children.Add(new TextBlock { Text = $"{r.Name} ({Label(r.Platform)}) wants to pair", TextWrapping = TextWrapping.Wrap, FontWeight = FontWeights.SemiBold });
            var buttons = new StackPanel { Orientation = Orientation.Horizontal, Margin = new Thickness(0, 8, 0, 0) };
            var allow = Button("Allow", async () => await _model.AllowAsync(r), accent: true);
            allow.Margin = new Thickness(0, 0, 8, 0);
            buttons.Children.Add(allow);
            buttons.Children.Add(Button("Deny", () => _model.Deny(r)));
            stack.Children.Add(buttons);
            card.Child = stack;
            Add(card);
        }
    }

    private void Pairing(string code)
    {
        Section("Pair a device");
        var card = Card();
        var stack = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center };
        stack.Children.Add(new Image { Source = Qr(code), Width = 220, Height = 220, Margin = new Thickness(0, 4, 0, 8) });
        stack.Children.Add(new TextBlock
        {
            Text = "Scan this with Teleport on your phone, then click Allow here.\nValid for 10 minutes, for one device.",
            TextAlignment = TextAlignment.Center, TextWrapping = TextWrapping.Wrap, Foreground = Secondary,
        });
        var done = Button("Done", _model.HidePairingCode);
        done.HorizontalAlignment = HorizontalAlignment.Center;
        done.Margin = new Thickness(0, 10, 0, 0);
        stack.Children.Add(done);
        card.Child = stack;
        Add(card);
    }

    private void Devices()
    {
        Section("Devices");
        if (_model.Peers.Count == 0)
        {
            Add(Caption("No devices yet. Click \"Pair a device\" and scan the code with Teleport on your phone.", Secondary));
            return;
        }
        foreach (var peer in _model.Peers)
        {
            var row = new DockPanel { Margin = new Thickness(0, 2, 0, 2) };
            var remove = new Button
            {
                Content = Glyph(""), ToolTip = $"Remove {peer.Name}", Padding = new Thickness(8, 4, 8, 4),
                Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            };
            remove.Click += (_, _) =>
            {
                _renaming = true;
                var answer = MessageBox.Show(this, $"Remove {peer.Name}? You'll need to pair again to use it.", "Teleport", MessageBoxButton.OKCancel);
                _renaming = false;
                if (answer == MessageBoxResult.OK) _model.Remove(peer);
            };
            DockPanel.SetDock(remove, Dock.Right);
            row.Children.Add(remove);
            var send = new Button
            {
                Content = Glyph(""), ToolTip = $"Send clipboard to {peer.Name}", Padding = new Thickness(8, 4, 8, 4),
                Background = Brushes.Transparent, BorderThickness = new Thickness(0),
            };
            send.Click += async (_, _) =>
            {
                if (AppModel.ReadClipboard() is { } clip) await _model.SendAsync(clip, peer);
                else _model.Toast("Nothing to send", "The clipboard is empty.");
            };
            DockPanel.SetDock(send, Dock.Right);
            row.Children.Add(send);
            var label = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
            label.Children.Add(Glyph(peer.Platform switch { "ios" or "android" => "", "mac" => "", _ => "" }));
            var names = new StackPanel { Margin = new Thickness(10, 0, 0, 0) };
            names.Children.Add(new TextBlock { Text = peer.Name, TextTrimming = TextTrimming.CharacterEllipsis });
            names.Children.Add(Caption(Label(peer.Platform), Secondary));
            label.Children.Add(names);
            row.Children.Add(label);
            Add(row);
        }
    }

    private void Settings()
    {
        var name = new DockPanel { Margin = new Thickness(0, 0, 0, 8) };
        name.Children.Add(new TextBlock { Text = "This PC", Foreground = Secondary, VerticalAlignment = VerticalAlignment.Center, Width = 70 });
        if (_renaming)
        {
            var box = new TextBox { Text = _model.Name, MinWidth = 200 };
            box.KeyDown += async (_, e) =>
            {
                if (e.Key == Key.Enter) { _renaming = false; await _model.RenameAsync(box.Text); Build(); }
                if (e.Key == Key.Escape) { _renaming = false; Build(); e.Handled = true; }
            };
            name.Children.Add(box);
            Dispatcher.BeginInvoke(() => { box.Focus(); box.SelectAll(); });
        }
        else
        {
            var rename = Button("Rename", () => { _renaming = true; Build(); });
            DockPanel.SetDock(rename, Dock.Right);
            name.Children.Add(rename);
            name.Children.Add(new TextBlock { Text = _model.Name, VerticalAlignment = VerticalAlignment.Center, TextTrimming = TextTrimming.CharacterEllipsis });
        }
        Add(name);

        Toggle("Start when I sign in", null, StartAtLogin.Enabled, v => StartAtLogin.Enabled = v);
        Toggle("Stay awake when plugged in", _model.KeepAwake.Active ? "Keeping this PC awake now. The screen still turns off." : "Keeps this PC reachable while plugged in. The screen still turns off.",
            _model.KeepAwakeOnPower, v => _model.KeepAwakeOnPower = v);
        Toggle("Save received images to Downloads", null, _model.SaveImages, v => _model.SaveImages = v);
        Toggle("Show hidden files to phones", "Dotfiles, AppData and hidden system files, when browsing this PC.", _model.ShowHiddenFiles, v => _model.ShowHiddenFiles = v);
        Toggle("\"Send to ▸ Teleport\" in File Explorer", null, SendToMenu.Installed, v => { if (v) SendToMenu.Install(); else SendToMenu.Remove(); });
        if (!_model.HardwareKeys && _model.Teleport is not null)
            Add(Caption("This PC's TPM isn't available, so Teleport's keys are stored in software.", Secondary));
    }

    private void Footer()
    {
        var row = new DockPanel();
        var quit = Button("Quit", () => Application.Current.Shutdown());
        DockPanel.SetDock(quit, Dock.Right);
        row.Children.Add(quit);
        var pair = Button("Pair a device…", _model.ShowPairingCode, accent: true);
        pair.HorizontalAlignment = HorizontalAlignment.Left;
        row.Children.Add(pair);
        Add(row);
    }

    // ---------- pieces ----------

    private static Brush Secondary => (Brush?)Application.Current.TryFindResource("TextFillColorSecondaryBrush") ?? Brushes.Gray;
    private static Brush Accent => (Brush?)Application.Current.TryFindResource("AccentTextFillColorPrimaryBrush") ?? SystemParameters.WindowGlassBrush;

    private void Add(UIElement e) => _root.Children.Add(e);

    private void Section(string title) =>
        Add(new TextBlock { Text = title, FontWeight = FontWeights.SemiBold, Margin = new Thickness(0, 12, 0, 6) });

    private void Separator() => Add(new Separator { Margin = new Thickness(0, 12, 0, 12) });

    private static TextBlock Caption(string text, Brush brush) => new()
    {
        Text = text, Foreground = brush, FontSize = 12, TextWrapping = TextWrapping.Wrap, Margin = new Thickness(0, 2, 0, 2),
    };

    private static TextBlock Glyph(string glyph) => new() { Text = glyph, FontFamily = new FontFamily("Segoe Fluent Icons"), FontSize = 16, VerticalAlignment = VerticalAlignment.Center };

    private static Border Card() => new()
    {
        Padding = new Thickness(12), Margin = new Thickness(0, 0, 0, 8), CornerRadius = new CornerRadius(8),
        Background = (Brush?)Application.Current.TryFindResource("CardBackgroundFillColorDefaultBrush") ?? Brushes.Transparent,
        BorderBrush = (Brush?)Application.Current.TryFindResource("CardStrokeColorDefaultBrush") ?? Brushes.LightGray,
        BorderThickness = new Thickness(1),
    };

    private static Button Button(string text, Action onClick, bool accent = false)
    {
        var b = new Button { Content = text, Padding = new Thickness(12, 5, 12, 6) };
        if (accent && Application.Current.TryFindResource("AccentButtonStyle") is Style style) b.Style = style;
        b.Click += (_, _) => onClick();
        return b;
    }

    private static Button Button(string text, Func<Task> onClick, bool accent = false) => Button(text, () => { _ = onClick(); }, accent);

    private void Toggle(string title, string? detail, bool value, Action<bool> set)
    {
        var box = new CheckBox { IsChecked = value, Margin = new Thickness(0, 4, 0, 4) };
        var text = new StackPanel();
        text.Children.Add(new TextBlock { Text = title, TextWrapping = TextWrapping.Wrap });
        if (detail is not null) text.Children.Add(Caption(detail, Secondary));
        box.Content = text;
        box.Click += (_, _) => { try { set(box.IsChecked == true); } catch (Exception e) { _model.Toast("Couldn't change that", e.Message); } Build(); };
        Add(box);
    }

    private static string Join(IReadOnlyList<string> names) => names.Count switch
    {
        1 => names[0],
        2 => $"{names[0]} and {names[1]}",
        _ => string.Join(", ", names.Take(names.Count - 1)) + " and " + names[^1],
    };

    private static string Label(string platform) => platform switch
    {
        "ios" => "iPhone", "android" => "Android phone", "mac" => "Mac", "windows" => "Windows PC", _ => platform,
    };

    private static BitmapImage Qr(string text)
    {
        using var generator = new QRCodeGenerator();
        using var data = generator.CreateQrCode(text, QRCodeGenerator.ECCLevel.M);
        var png = new PngByteQRCode(data).GetGraphic(10);
        var image = new BitmapImage();
        image.BeginInit();
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.StreamSource = new MemoryStream(png);
        image.EndInit();
        image.Freeze();
        return image;
    }
}
