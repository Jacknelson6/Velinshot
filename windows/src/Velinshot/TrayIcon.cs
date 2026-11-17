using Forms = System.Windows.Forms;

namespace Velinshot;

/// <summary>The notification-area icon and menu (the macOS menu-bar item's counterpart).</summary>
internal sealed class TrayIcon : IDisposable
{
    private readonly App app;
    private readonly Forms.NotifyIcon icon;
    private readonly Forms.ToolStripMenuItem captureItem, quickItem, reopenItem;

    public TrayIcon(App app)
    {
        this.app = app;
        var menu = new Forms.ContextMenuStrip();
        captureItem = new Forms.ToolStripMenuItem("Capture and Edit", null, (_, _) => app.Capture());
        quickItem = new Forms.ToolStripMenuItem("Capture and Copy", null, (_, _) => app.Capture(quickCopy: true));
        reopenItem = new Forms.ToolStripMenuItem("Reopen Closed Screenshot", null, (_, _) => app.ReopenClosed());
        menu.Items.Add(captureItem);
        menu.Items.Add(new Forms.ToolStripMenuItem("Capture Display", null, (_, _) => app.Capture(display: true)));
        menu.Items.Add(quickItem);
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(new Forms.ToolStripMenuItem("Open Image…", null, (_, _) => app.OpenImage()));
        menu.Items.Add(new Forms.ToolStripMenuItem("Open from Clipboard", null, (_, _) => app.OpenClipboard()));
        menu.Items.Add(reopenItem);
        menu.Items.Add(new Forms.ToolStripMenuItem("Screenshot History…", null, (_, _) => app.ShowHistory()));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(new Forms.ToolStripMenuItem("Settings…", null, (_, _) => app.ShowSettings()));
        menu.Items.Add(new Forms.ToolStripMenuItem("Check for Updates…", null, (_, _) => app.CheckForUpdates()));
        menu.Items.Add(new Forms.ToolStripMenuItem("About Velinshot", null, (_, _) => app.ShowAbout()));
        menu.Items.Add(new Forms.ToolStripSeparator());
        menu.Items.Add(new Forms.ToolStripMenuItem("Quit Velinshot", null, (_, _) => app.Quit()));
        menu.Opening += (_, _) => reopenItem.Enabled = app.CanReopen;
        using var stream = System.Windows.Application.GetResourceStream(new Uri("pack://application:,,,/Resources/Velinshot.ico"))!.Stream;
        icon = new Forms.NotifyIcon
        {
            Icon = new System.Drawing.Icon(stream, Forms.SystemInformation.SmallIconSize),
            ContextMenuStrip = menu,
            Visible = true
        };
        icon.MouseClick += (_, e) => { if (e.Button == Forms.MouseButtons.Left) app.ShowWelcome(); };
        Refresh();
    }

    public void Refresh()
    {
        var settings = app.Settings;
        captureItem.ShortcutKeyDisplayString = settings.CaptureShortcut.Display;
        quickItem.ShortcutKeyDisplayString = settings.QuickCopyShortcut.Display;
        icon.Text = $"Velinshot · {settings.CaptureShortcut.Display} to capture";
    }

    public void Notify(string title, string message) => icon.ShowBalloonTip(3000, title, message, Forms.ToolTipIcon.None);

    public void Dispose()
    {
        icon.Visible = false;
        icon.Dispose();
    }
}
