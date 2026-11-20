using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Runtime.InteropServices;
using Microsoft.Win32;
using Teleport.Core;
using Forms = System.Windows.Forms;

namespace Teleport.Windows;

/// The notification-area icon: left-click opens the panel, right-click a short menu.
/// The glyph is drawn from Segoe Fluent Icons to match Windows 11's own tray icons,
/// light or dark to suit the taskbar, and dimmed while offline.
public sealed class Tray : IDisposable
{
    private readonly AppModel _model;
    private readonly Forms.NotifyIcon _icon = new();
    private readonly PanelWindow _panel;
    private Action? _balloonClick;
    private (bool online, bool light)? _drawn;

    public Tray(AppModel model)
    {
        _model = model;
        _panel = new PanelWindow(model);
        model.OpenPanel = ShowPanel;
        _icon.MouseUp += (_, e) => { if (e.Button == Forms.MouseButtons.Left) TogglePanel(); };
        _icon.BalloonTipClicked += (_, _) => { _balloonClick?.Invoke(); _balloonClick = null; };
        _icon.ContextMenuStrip = new Forms.ContextMenuStrip();
        _icon.ContextMenuStrip.Opening += (_, _) => BuildMenu();
        model.Changed += Refresh;
        model.Notify += (title, text, onClick) => { _balloonClick = onClick; _icon.ShowBalloonTip(5000, title, text, Forms.ToolTipIcon.None); };
        SystemEvents.UserPreferenceChanged += (_, _) => Refresh();
        Refresh();
        _icon.Visible = true;
    }

    private void Refresh()
    {
        var online = _model.IsOnline;
        var light = TaskbarIsLight();
        var tip = $"Teleport: {(online ? "online" : "offline")}";
        if (_model.Browsers.Count > 0) tip = $"Teleport: {string.Join(", ", _model.Browsers)} browsing";
        _icon.Text = tip.Length > 63 ? tip[..63] : tip;
        if (_drawn == (online, light)) return;
        _drawn = (online, light);
        var old = _icon.Icon;
        _icon.Icon = DrawIcon(online, light);
        if (old is not null) { DestroyIcon(old.Handle); old.Dispose(); }
    }

    public void ShowPanel() => _panel.ShowNearTray();
    private void TogglePanel() { if (_panel.IsVisible) _panel.Hide(); else ShowPanel(); }

    private void BuildMenu()
    {
        var menu = _icon.ContextMenuStrip!;
        menu.Items.Clear();
        var send = new Forms.ToolStripMenuItem("Send clipboard to");
        foreach (var peer in _model.Peers)
        {
            var p = peer;
            send.DropDownItems.Add(peer.Name, null, async (_, _) =>
            {
                if (AppModel.ReadClipboard() is { } clip) await _model.SendAsync(clip, p);
                else _model.Toast("Nothing to send", "The clipboard is empty.");
            });
        }
        send.Enabled = _model.Peers.Count > 0;
        menu.Items.Add(send);
        menu.Items.Add("Open Teleport", null, (_, _) => ShowPanel());
        menu.Items.Add("Pair a device…", null, (_, _) => { _model.ShowPairingCode(); ShowPanel(); });
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add("Quit Teleport", null, (_, _) => System.Windows.Application.Current.Shutdown());
    }

    private static bool TaskbarIsLight() =>
        Registry.CurrentUser.OpenSubKey(@"Software\Microsoft\Windows\CurrentVersion\Themes\Personalize")?.GetValue("SystemUsesLightTheme") is 1;

    [DllImport("user32.dll")]
    private static extern bool DestroyIcon(IntPtr handle);

    /// Segoe Fluent Icons "Send" (U+E724) on a transparent square.
    private static Icon DrawIcon(bool online, bool lightTaskbar)
    {
        var size = Forms.SystemInformation.SmallIconSize.Width;
        using var bmp = new Bitmap(size, size);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAliasGridFit;
            var colour = lightTaskbar ? Color.FromArgb(online ? 255 : 120, 25, 25, 25) : Color.FromArgb(online ? 255 : 120, 255, 255, 255);
            using var font = new Font("Segoe Fluent Icons", size * 0.62f, GraphicsUnit.Pixel);
            using var brush = new SolidBrush(colour);
            var glyph = online ? "" : "";  // Send, or Disconnected
            var measured = g.MeasureString(glyph, font, PointF.Empty, StringFormat.GenericTypographic);
            g.DrawString(glyph, font, brush, (size - measured.Width) / 2, (size - measured.Height) / 2, StringFormat.GenericTypographic);
        }
        return Icon.FromHandle(bmp.GetHicon());
    }

    public void Dispose()
    {
        _icon.Visible = false;
        _icon.Dispose();
        _panel.Close();
    }
}
