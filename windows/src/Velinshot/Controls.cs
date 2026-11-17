using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using Velinshot.Core;

namespace Velinshot;

/// <summary>A color well: a swatch and hex value that opens a palette popup with a hex field
/// and the system color dialog for anything else.</summary>
internal sealed class ColorButton : Button
{
    private static readonly string[] Palette =
    {
        "F05A6E", "EC687C", "F97316", "F7C45C", "FFD400", "2E9E5B",
        "1FA2A8", "3B82F6", "7160E8", "B7AEF8", "191A25", "8B8397", "FFFFFF", "000000"
    };

    private readonly Border sample = new() { Width = 22, Height = 22, CornerRadius = new CornerRadius(5), BorderThickness = new Thickness(1) };
    private readonly TextBlock hex = new() { FontSize = 12, VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(8, 0, 0, 0) };
    private Rgba color;

    public event Action<Rgba>? ColorChanged;

    public ColorButton(string accessibleName, bool prominent = false)
    {
        SetResourceReference(StyleProperty, "Studio.SecondaryButton");
        Height = prominent ? 40 : 32;
        Padding = new Thickness(6, 0, 10, 0);
        HorizontalContentAlignment = HorizontalAlignment.Left;
        sample.Width = sample.Height = prominent ? 26 : 20;
        sample.SetResourceReference(Border.BorderBrushProperty, "StudioDivider");
        hex.FontFamily = new FontFamily("Cascadia Mono, Consolas");
        hex.FontSize = prominent ? 12.5 : 11.5;
        Content = new StackPanel { Orientation = Orientation.Horizontal, Children = { sample, hex } };
        AutomationProperties.SetName(this, accessibleName);
        Click += (_, _) => OpenPopup();
    }

    public Rgba Color
    {
        get => color;
        set
        {
            color = value;
            sample.Background = new SolidColorBrush(value.WithAlpha(Math.Max(value.Alpha, 0.0)).ToColor());
            hex.Text = value.Hex;
            AutomationProperties.SetItemStatus(this, value.Hex);
        }
    }

    private void Choose(Rgba value)
    {
        Color = value;
        ColorChanged?.Invoke(value);
    }

    private void OpenPopup()
    {
        var popup = new Popup { PlacementTarget = this, Placement = PlacementMode.Bottom, StaysOpen = false, AllowsTransparency = true };
        var grid = new UniformGrid { Columns = 7, Margin = new Thickness(0, 0, 0, 10) };
        foreach (var value in Palette)
        {
            var swatch = Rgba.FromHex(value);
            var button = new Button { Background = new SolidColorBrush(swatch.ToColor()), Margin = new Thickness(2), ToolTip = "#" + value };
            button.SetResourceReference(StyleProperty, "Studio.Swatch");
            AutomationProperties.SetName(button, "#" + value);
            button.Click += (_, _) => { popup.IsOpen = false; Choose(swatch.WithAlpha(color.Alpha <= 0 ? 1 : color.Alpha)); };
            grid.Children.Add(button);
        }
        var field = new TextBox { Text = color.Hex, Width = 110, FontSize = 13, VerticalContentAlignment = VerticalAlignment.Center };
        AutomationProperties.SetName(field, "Hex color");
        field.KeyDown += (_, e) =>
        {
            if (e.Key != Key.Enter) return;
            var text = field.Text.Trim().TrimStart('#');
            if (text.Length == 6 && text.All(Uri.IsHexDigit)) { popup.IsOpen = false; Choose(Rgba.FromHex(text).WithAlpha(color.Alpha <= 0 ? 1 : color.Alpha)); }
            e.Handled = true;
        };
        var more = UI.Button("More colors…", null, () => { popup.IsOpen = false; SystemDialog(); }, "Studio.SecondaryButton");
        more.Height = 32;
        more.Margin = new Thickness(8, 0, 0, 0);
        var row = new StackPanel { Orientation = Orientation.Horizontal, Children = { field, more } };
        var card = new Border
        {
            Padding = new Thickness(12), CornerRadius = new CornerRadius(10), BorderThickness = new Thickness(1),
            Child = new StackPanel { Children = { grid, row } },
            Effect = new System.Windows.Media.Effects.DropShadowEffect { BlurRadius = 18, ShadowDepth = 4, Opacity = 0.22 },
            Margin = new Thickness(8)
        };
        card.SetResourceReference(Border.BackgroundProperty, "StudioSurface");
        card.SetResourceReference(Border.BorderBrushProperty, "StudioDivider");
        popup.Child = card;
        popup.Opened += (_, _) => field.Focus();
        popup.IsOpen = true;
    }

    private void SystemDialog()
    {
        using var dialog = new System.Windows.Forms.ColorDialog { FullOpen = true, AnyColor = true };
        var current = color.ToColor();
        dialog.Color = System.Drawing.Color.FromArgb(current.R, current.G, current.B);
        var owner = Window.GetWindow(this);
        var handle = owner is null ? IntPtr.Zero : new WindowInteropHelper(owner).Handle;
        if (dialog.ShowDialog(new Win32Owner(handle)) != System.Windows.Forms.DialogResult.OK) return;
        var chosen = dialog.Color;
        Choose(new Rgba(chosen.R / 255.0, chosen.G / 255.0, chosen.B / 255.0, color.Alpha <= 0 ? 1 : color.Alpha));
    }

    private sealed class Win32Owner(IntPtr handle) : System.Windows.Forms.IWin32Window
    {
        public IntPtr Handle { get; } = handle;
    }
}

internal static class Dialogs
{
    /// <summary>A small modal prompt that returns the entered text, or null when cancelled.</summary>
    public static string? Ask(Window owner, string title, string message, string placeholder, string initial = "")
    {
        var window = new Window
        {
            Title = title, Owner = owner, Width = 400, SizeToContent = SizeToContent.Height, ResizeMode = ResizeMode.NoResize,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ShowInTaskbar = false
        };
        window.SetResourceReference(Window.BackgroundProperty, "StudioSurface");
        window.SourceInitialized += (_, _) => Theme.ApplyTitleBar(window);
        var field = new TextBox { Text = initial, FontSize = 14, Margin = new Thickness(0, 12, 0, 18), ToolTip = placeholder };
        AutomationProperties.SetName(field, title);
        var ok = UI.Button("OK", null, () => window.DialogResult = true, "Studio.PrimaryButton");
        ok.IsDefault = true; ok.Width = 96; ok.Height = 34;
        var cancel = UI.Button("Cancel", null, () => window.DialogResult = false, "Studio.SecondaryButton");
        cancel.IsCancel = true; cancel.Width = 96; cancel.Height = 34; cancel.Margin = new Thickness(0, 0, 8, 0);
        var hint = UI.Label($"Example: {placeholder}", 12, secondary: true);
        var text = UI.Label(message, 13);
        text.TextWrapping = TextWrapping.Wrap;
        window.Content = new StackPanel
        {
            Margin = new Thickness(20),
            Children =
            {
                UI.Label(title, 15, FontWeights.SemiBold), new Border { Height = 6 }, text, field, hint,
                new StackPanel { Orientation = Orientation.Horizontal, HorizontalAlignment = HorizontalAlignment.Right, Margin = new Thickness(0, 16, 0, 0), Children = { cancel, ok } }
            }
        };
        window.Loaded += (_, _) => { field.Focus(); field.SelectAll(); };
        return window.ShowDialog() == true ? field.Text : null;
    }

    public static void Error(Window? owner, Exception error) => Error(owner, error.Message);

    public static void Error(Window? owner, string message)
    {
        if (owner is { IsVisible: true }) MessageBox.Show(owner, message, "Velinshot", MessageBoxButton.OK, MessageBoxImage.Warning);
        else MessageBox.Show(message, "Velinshot", MessageBoxButton.OK, MessageBoxImage.Warning);
    }

    /// <summary>A resizable window with selectable recognized text.</summary>
    public static Window TextWindow(Window owner, string text)
    {
        var window = new Window { Title = "Recognized text", Width = 520, Height = 350, Owner = owner, WindowStartupLocation = WindowStartupLocation.CenterOwner };
        window.SetResourceReference(Window.BackgroundProperty, "StudioSurface");
        window.SourceInitialized += (_, _) => Theme.ApplyTitleBar(window);
        var box = new TextBox
        {
            Text = text.Length == 0 ? "No text was found. Try a larger or sharper image." : text,
            IsReadOnly = true, TextWrapping = TextWrapping.Wrap, AcceptsReturn = true, FontSize = 14, Padding = new Thickness(12),
            VerticalScrollBarVisibility = ScrollBarVisibility.Auto, BorderThickness = new Thickness(0)
        };
        AutomationProperties.SetName(box, "Recognized text");
        var copy = UI.Button("Copy all", "copy", () => { try { Clipboard.SetText(box.Text); } catch (Exception) { } }, "Studio.SecondaryButton", iconSize: 16);
        copy.Height = 34;
        var bar = new DockPanel { Margin = new Thickness(12, 8, 12, 12), LastChildFill = false };
        DockPanel.SetDock(copy, Dock.Right);
        bar.Children.Add(copy);
        var root = new DockPanel();
        DockPanel.SetDock(bar, Dock.Bottom);
        root.Children.Add(bar);
        root.Children.Add(box);
        window.Content = root;
        window.Show();
        box.Focus();
        box.SelectAll();
        return window;
    }
}
