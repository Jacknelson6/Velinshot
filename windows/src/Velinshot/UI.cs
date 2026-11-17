using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using System.Windows.Threading;

namespace Velinshot;

/// <summary>Small factories that keep window code readable.</summary>
internal static class UI
{
    public static TextBlock Label(string text, double size = 13, FontWeight? weight = null, bool secondary = false)
    {
        var label = new TextBlock { Text = text, FontSize = size, FontWeight = weight ?? FontWeights.Normal, TextTrimming = TextTrimming.CharacterEllipsis, VerticalAlignment = VerticalAlignment.Center };
        label.SetResourceReference(TextBlock.ForegroundProperty, secondary ? "StudioSecondaryText" : "StudioText");
        return label;
    }

    public static TextBlock Caption(string text)
    {
        var caption = new TextBlock { Text = text };
        caption.SetResourceReference(FrameworkElement.StyleProperty, "Studio.Caption");
        return caption;
    }

    public static object Content(string? icon, string? text, double iconSize = 18, bool trailingIcon = false)
    {
        if (icon is null) return text ?? "";
        if (string.IsNullOrEmpty(text)) return Icons.Make(icon, iconSize);
        var panel = new StackPanel { Orientation = Orientation.Horizontal };
        var glyph = Icons.Make(icon, iconSize);
        var label = new TextBlock { Text = text, VerticalAlignment = VerticalAlignment.Center };
        if (trailingIcon) { label.Margin = new Thickness(0, 0, 6, 0); panel.Children.Add(label); panel.Children.Add(glyph); }
        else { label.Margin = new Thickness(8, 0, 0, 0); panel.Children.Add(glyph); panel.Children.Add(label); }
        return panel;
    }

    public static Button Button(string? text, string? icon, Action action, string style = "Studio.Button", string? tooltip = null, double iconSize = 18)
    {
        var button = new Button { Content = Content(icon, text, iconSize) };
        button.SetResourceReference(FrameworkElement.StyleProperty, style);
        button.Click += (_, _) => action();
        if (tooltip is not null) button.ToolTip = tooltip;
        AutomationProperties.SetName(button, text is { Length: > 0 } ? text : tooltip ?? icon ?? "");
        return button;
    }

    /// <summary>A full-width inspector action with a leading icon.</summary>
    public static Button Action(string text, string icon, Action action)
    {
        var button = Button(text, icon, action, "Studio.SecondaryButton", iconSize: 16);
        button.HorizontalContentAlignment = HorizontalAlignment.Left;
        button.Height = 36;
        return button;
    }

    public static CheckBox Check(string text, bool value, Action<bool> changed)
    {
        var box = new CheckBox { Content = text, IsChecked = value, FontSize = 13, VerticalAlignment = VerticalAlignment.Center };
        box.SetResourceReference(Control.ForegroundProperty, "StudioText");
        box.Click += (_, _) => changed(box.IsChecked == true);
        return box;
    }

    public static ComboBox Picker(IEnumerable<string> items, string accessibleName)
    {
        var picker = new ComboBox { FontSize = 13, HorizontalAlignment = HorizontalAlignment.Stretch };
        foreach (var item in items) picker.Items.Add(item);
        AutomationProperties.SetName(picker, accessibleName);
        return picker;
    }

    /// <summary>A segmented control built from radio buttons on a field-colored track.</summary>
    public static (Border Track, RadioButton[] Segments) Segments(string[] labels, string group, Action<int> selected)
    {
        var grid = new UniformGrid { Rows = 1, Columns = labels.Length };
        var segments = new RadioButton[labels.Length];
        for (var i = 0; i < labels.Length; i++)
        {
            var index = i;
            var segment = new RadioButton { Content = labels[i], GroupName = group };
            segment.SetResourceReference(FrameworkElement.StyleProperty, "Studio.Segment");
            segment.Checked += (_, _) => selected(index);
            segments[i] = segment;
            grid.Children.Add(segment);
        }
        var track = new Border { CornerRadius = new CornerRadius(8), Child = grid };
        track.SetResourceReference(Border.BackgroundProperty, "StudioField");
        return (track, segments);
    }

    public static Border Surface(UIElement? child = null, string brush = "StudioSurface")
    {
        var border = new Border { Child = child };
        border.SetResourceReference(Border.BackgroundProperty, brush);
        return border;
    }

    public static BitmapImage AppIcon(int decodeWidth = 64)
    {
        var image = new BitmapImage();
        image.BeginInit();
        image.UriSource = new Uri("pack://application:,,,/Resources/AppIcon.png");
        image.DecodePixelWidth = decodeWidth;
        image.CacheOption = BitmapCacheOption.OnLoad;
        image.EndInit();
        image.Freeze();
        return image;
    }

    public static void Defer(Action action, DispatcherPriority priority = DispatcherPriority.Background) =>
        Dispatcher.CurrentDispatcher.BeginInvoke(priority, action);
}

/// <summary>A background STA thread with its own dispatcher. WPF imaging (DrawingVisual,
/// RenderTargetBitmap) requires STA, so engine work runs here instead of the thread pool.</summary>
internal sealed class StaWorker
{
    public static readonly StaWorker Preview = new("Velinshot preview");
    public static readonly StaWorker Work = new("Velinshot work");

    private readonly Dispatcher dispatcher;

    private StaWorker(string name)
    {
        Dispatcher? created = null;
        using var ready = new ManualResetEventSlim();
        var thread = new Thread(() =>
        {
            created = Dispatcher.CurrentDispatcher;
            ready.Set();
            Dispatcher.Run();
        }) { IsBackground = true, Name = name, Priority = ThreadPriority.AboveNormal };
        thread.SetApartmentState(ApartmentState.STA);
        thread.Start();
        ready.Wait();
        dispatcher = created!;
    }

    public Task<T> Run<T>(Func<T> work) => dispatcher.InvokeAsync(work, DispatcherPriority.Normal).Task;

    public Task<T> RunAsync<T>(Func<Task<T>> work) => dispatcher.InvokeAsync(work, DispatcherPriority.Normal).Task.Unwrap();
}

/// <summary>Latest-wins background work: a new submission supersedes the previous one, and a
/// superseded result never reaches the UI.</summary>
internal sealed class LatestWork<T>
{
    private int generation;
    public bool IsBusy { get; private set; }

    public void Cancel() { generation++; IsBusy = false; }

    public async void Submit(Func<T> work, Action<T> success, Action<Exception> failure)
    {
        var ticket = ++generation;
        IsBusy = true;
        try
        {
            var result = await StaWorker.Work.Run(work);
            if (ticket != generation) return;
            IsBusy = false;
            success(result);
        }
        catch (Exception error)
        {
            if (ticket != generation) return;
            IsBusy = false;
            failure(error);
        }
    }
}
