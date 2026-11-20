using System.Runtime.InteropServices;
using Microsoft.Win32;

namespace Teleport.Windows;

/// Starts Teleport when you sign in (the per-user Run key: no admin, no installer).
public static class StartAtLogin
{
    private const string RunKey = @"Software\Microsoft\Windows\CurrentVersion\Run";
    private const string Name = "Teleport";

    public static bool Enabled
    {
        get => Registry.CurrentUser.OpenSubKey(RunKey)?.GetValue(Name) is string;
        set
        {
            using var key = Registry.CurrentUser.CreateSubKey(RunKey);
            if (value) key.SetValue(Name, $"\"{Environment.ProcessPath}\" --background");
            else key.DeleteValue(Name, throwOnMissingValue: false);
        }
    }
}

/// Keeps the PC from idle-sleeping while it's plugged in, so phones can reach it.
/// The display still sleeps. Re-evaluated when power changes.
public sealed class KeepAwake : IDisposable
{
    [Flags]
    private enum ExecutionState : uint { SystemRequired = 0x1, Continuous = 0x80000000 }

    [DllImport("kernel32.dll")]
    private static extern ExecutionState SetThreadExecutionState(ExecutionState flags);

    private readonly System.Windows.Threading.DispatcherTimer _timer = new() { Interval = TimeSpan.FromMinutes(1) };
    private bool _enabled;

    /// Whether it's holding the PC awake right now.
    public bool Active { get; private set; }
    public event Action? Changed;

    public KeepAwake()
    {
        _timer.Tick += (_, _) => Apply();
        SystemEvents.PowerModeChanged += (_, _) => Apply();
        _timer.Start();
    }

    public bool Enabled { get => _enabled; set { _enabled = value; Apply(); } }

    private static bool OnPower => System.Windows.Forms.SystemInformation.PowerStatus.PowerLineStatus == System.Windows.Forms.PowerLineStatus.Online;

    private void Apply()
    {
        var want = _enabled && OnPower;
        if (want == Active) return;
        // The execution state belongs to the calling thread: always set it from the UI thread.
        SetThreadExecutionState(want ? ExecutionState.Continuous | ExecutionState.SystemRequired : ExecutionState.Continuous);
        Active = want;
        Changed?.Invoke();
    }

    public void Dispose()
    {
        _timer.Stop();
        SetThreadExecutionState(ExecutionState.Continuous);
    }
}

/// "Send to ▸ Teleport" in File Explorer's right-click menu: a shortcut in the SendTo folder.
public static class SendToMenu
{
    private static string ShortcutPath => Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.SendTo), "Teleport.lnk");

    public static bool Installed => File.Exists(ShortcutPath);

    public static void Install()
    {
        // WScript.Shell creates .lnk files without extra dependencies.
        var shellType = Type.GetTypeFromProgID("WScript.Shell") ?? throw new InvalidOperationException("WScript.Shell unavailable");
        dynamic shell = Activator.CreateInstance(shellType)!;
        try
        {
            dynamic link = shell.CreateShortcut(ShortcutPath);
            link.TargetPath = Environment.ProcessPath;
            link.Arguments = "--send";
            link.Description = "Send to a paired device with Teleport";
            link.IconLocation = Environment.ProcessPath + ",0";
            link.Save();
            Marshal.FinalReleaseComObject(link);
        }
        finally { Marshal.FinalReleaseComObject(shell); }
    }

    public static void Remove()
    {
        if (File.Exists(ShortcutPath)) File.Delete(ShortcutPath);
    }
}

/// Thumbnails for file previews on the phones: the same images Explorer shows,
/// from the shell's thumbnail cache (IShellItemImageFactory), encoded as JPEG.
public static class Thumbnails
{
    [ComImport, Guid("bcc18b79-ba16-442f-80c4-8a59c30c463b"), InterfaceType(ComInterfaceType.InterfaceIsIUnknown)]
    private interface IShellItemImageFactory
    {
        [PreserveSig] int GetImage(Size size, int flags, out IntPtr bitmap);
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct Size { public int Cx, Cy; }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode, PreserveSig = false)]
    private static extern void SHCreateItemFromParsingName(string path, IntPtr bindContext, [MarshalAs(UnmanagedType.LPStruct)] Guid riid,
        [MarshalAs(UnmanagedType.Interface)] out IShellItemImageFactory factory);

    [DllImport("gdi32.dll")]
    private static extern bool DeleteObject(IntPtr handle);

    private const int ThumbnailOnly = 0x08;   // SIIGBF_THUMBNAILONLY: no generic file-type icons
    private const int BiggerSizeOk = 0x01;    // SIIGBF_BIGGERSIZEOK

    public static Task<byte[]?> JpegAsync(string path, int px)
    {
        // Shell COM objects want an STA thread.
        var done = new TaskCompletionSource<byte[]?>();
        var thread = new Thread(() =>
        {
            try { done.SetResult(Jpeg(path, px)); }
            catch { done.SetResult(null); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        return done.Task;
    }

    private static byte[]? Jpeg(string path, int px)
    {
        SHCreateItemFromParsingName(path, IntPtr.Zero, typeof(IShellItemImageFactory).GUID, out var factory);
        try
        {
            if (factory.GetImage(new Size { Cx = px, Cy = px }, ThumbnailOnly | BiggerSizeOk, out var hbitmap) != 0) return null;
            try
            {
                using var bmp = System.Drawing.Image.FromHbitmap(hbitmap);
                // Shell bitmaps can carry alpha; flatten onto white for JPEG.
                using var flat = new System.Drawing.Bitmap(bmp.Width, bmp.Height);
                using (var g = System.Drawing.Graphics.FromImage(flat))
                {
                    g.Clear(System.Drawing.Color.White);
                    g.DrawImage(bmp, 0, 0, bmp.Width, bmp.Height);
                }
                using var ms = new MemoryStream();
                var codec = System.Drawing.Imaging.ImageCodecInfo.GetImageEncoders().First(c => c.MimeType == "image/jpeg");
                using var parameters = new System.Drawing.Imaging.EncoderParameters(1);
                parameters.Param[0] = new System.Drawing.Imaging.EncoderParameter(System.Drawing.Imaging.Encoder.Quality, 80L);
                flat.Save(ms, codec, parameters);
                return ms.ToArray();
            }
            finally { DeleteObject(hbitmap); }
        }
        finally { Marshal.ReleaseComObject(factory); }
    }
}

/// Simple append-only log at %LOCALAPPDATA%\Teleport\teleport.log (tools/win logs reads it).
public static class Log
{
    private static readonly object Lock = new();
    public static string Folder { get; } = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData), "Teleport");
    private static readonly string File_ = Path.Combine(Folder, "teleport.log");

    public static void Write(string message)
    {
        lock (Lock)
        {
            try
            {
                Directory.CreateDirectory(Folder);
                if (File.Exists(File_) && new FileInfo(File_).Length > 1_000_000) File.Move(File_, File_ + ".old", overwrite: true);
                File.AppendAllText(File_, $"{DateTime.Now:yyyy-MM-dd HH:mm:ss} {message}{Environment.NewLine}");
            }
            catch (IOException) { }
        }
    }
}
