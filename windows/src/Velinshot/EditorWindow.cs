using System.IO;
using System.Windows;
using System.Windows.Automation;
using System.Windows.Controls;
using System.Windows.Controls.Primitives;
using System.Windows.Documents;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Media;
using System.Windows.Media.Imaging;
using Velinshot.Core;

namespace Velinshot;

/// <summary>The compact editor: header actions, tool rail, canvas, a narrow inspector and the
/// Copy/Save footer. Dimensions follow DESIGN.md (header 60, rail 64, inspector 250, footer 64).</summary>
internal sealed class EditorWindow : Window
{
    private static readonly (string Name, double Width, double Height)[] Ratios =
    {
        ("Original ratio", 0, 0), ("4:3  Classic", 4, 3), ("3:2  Photo", 3, 2), ("1:1  Square", 1, 1), ("4:5  Portrait", 4, 5),
        ("9:16  Story", 9, 16), ("16:9  Wide", 16, 9), ("1.91:1  Social", 1.91, 1)
    };
    private static readonly (string Name, int Width, int Height)[] Sizes =
    {
        ("Instagram · 1080 × 1080", 1080, 1080), ("Portrait · 1080 × 1350", 1080, 1350), ("Stories · 1080 × 1920", 1080, 1920),
        ("X / Twitter · 1600 × 900", 1600, 900), ("Facebook · 1200 × 630", 1200, 630), ("LinkedIn · 1200 × 627", 1200, 627),
        ("YouTube · 1280 × 720", 1280, 720), ("Pinterest · 1000 × 1500", 1000, 1500), ("Reddit · 1200 × 628", 1200, 628)
    };
    private static readonly double[] Widths = { 3, 6, 12 };
    private static readonly double[] FontSizes = { 24, 36, 48, 72, 96 };
    private static readonly EditorTool[] RailTools =
        { EditorTool.Select, EditorTool.Arrow, EditorTool.Rectangle, EditorTool.Text, EditorTool.Highlighter, EditorTool.Redact, EditorTool.Crop };
    private static readonly EditorTool[] SecondaryTools = { EditorTool.Pen, EditorTool.Line, EditorTool.Ellipse, EditorTool.Number, EditorTool.Blur };

    public CanvasView Canvas { get; }
    public BitmapSource Source { get; }
    public HistoryEntry? HistoryEntry { get; set; }
    public string DocumentTitle { get; }

    public event Action? CaptureRequested, OpenRequested, PasteRequested, SettingsRequested, HistoryRequested, ReopenRequested,
        DemoRequested, ShortcutsRequested, UpdatesRequested, AboutRequested;
    public event Action<string>? ImportFileRequested;
    public event Action<BitmapSource>? ImportBitmapRequested;

    private readonly AppSettings preferences;
    private readonly PresetStore presetStore;
    private readonly EditHistory history = new();
    private readonly Dictionary<EditorTool, ToggleButton> toolButtons = new();
    private readonly Dictionary<string, (Slider Slider, TextBlock Value)> sliders = new();
    private readonly List<StackPanel> pages = new();
    private readonly TextBlock heading = UI.Label("Composition", 15, FontWeights.SemiBold);
    private readonly TextBlock markupDescription = UI.Label("Arrow", 14, FontWeights.SemiBold);
    private readonly TextBlock markupGuidance = UI.Label("", 12, secondary: true);
    private readonly TextBlock statusLabel = UI.Label("", 12, secondary: true);
    private readonly TextBlock dimensionsLabel = UI.Label("", 12, FontWeights.Medium);
    private readonly ColorButton firstColor = new("First background color");
    private readonly ColorButton secondColor = new("Second background color");
    private readonly ColorButton insetColor = new("Inset fill color", prominent: true);
    private readonly ColorButton annotationColor = new("Annotation color");
    private readonly ColorButton watermarkColor = new("Watermark color");
    private readonly TextBox watermarkField = new() { FontSize = 13, Height = 32, VerticalContentAlignment = VerticalAlignment.Center };
    private ComboBox backgroundPicker = null!, ratioPicker = null!, scalePicker = null!, presetPicker = null!, watermarkPosition = null!, fontPicker = null!;
    private CheckBox balanceCheck = null!, autoColorCheck = null!, autoInsetCheck = null!;
    private RadioButton[] widthSegments = null!;
    private RadioButton[] tabSegments = null!;
    private Border tabs = null!, widthTrack = null!;
    private StackPanel markupSection = null!, advancedSection = null!;
    private FrameworkElement annotationColorRow = null!;
    private Button resetCropButton = null!, advancedButton = null!, undoButton = null!, redoButton = null!, moreButton = null!;
    private ToggleButton moreToolsButton = null!;
    private ScrollViewer inspectorScroll = null!;
    private List<StylePreset> presets = new();
    private DocumentAnalysis analysis;
    private readonly LatestWork<DocumentAnalysis> analysisWork = new();
    private readonly LatestWork<(BitmapSource Image, string Id)> backgroundWork = new();
    private KnownContentBounds? insetJobCrop;
    private bool insetRefreshPending, insetRefreshScheduled, userIsClosing, syncing, textEditingActive, busyExporting, recognizing;
    private EditState? inspectorGestureBefore, watermarkGestureBefore;
    private string? loadedBackgroundId, pendingBackgroundId, historyFailure;
    private Window? infoWindow;
    private Point? dragStart;

    public EditorWindow(BitmapSource source, EditState? state, string title, ImagePreview? preparedPreview, DocumentAnalysis? preparedAnalysis,
                        AppSettings preferences)
    {
        this.preferences = preferences;
        Source = source;
        DocumentTitle = title;
        presetStore = new PresetStore(Path.Combine(AppSettings.SupportDirectory, "presets.json"));
        analysis = preparedAnalysis ?? new DocumentAnalysis();
        EditState initial;
        if (state is not null) initial = state;
        else
        {
            var prepared = NewDocument.Prepare(source, preferences.Style);
            initial = prepared.State;
            analysis = prepared.Analysis;
        }
        Canvas = new CanvasView(source, initial, preparedPreview);

        Title = $"{title} – Velinshot";
        Icon = UI.AppIcon(64);
        var work = SystemParameters.WorkArea;
        Width = Math.Min(950, work.Width - 32);
        Height = Math.Min(650, work.Height - 32);
        MinWidth = Math.Min(820, work.Width - 32);
        MinHeight = Math.Min(560, work.Height - 32);
        WindowStartupLocation = WindowStartupLocation.CenterScreen;
        SetResourceReference(BackgroundProperty, "StudioSurface");
        FontFamily = (FontFamily)FindResource("StudioFont");
        UseLayoutRounding = true;
        SourceInitialized += (_, _) => Theme.ApplyTitleBar(this);

        Content = BuildInterface();
        Canvas.Commit += (before, after) => Commit(before, after);
        Canvas.GestureEnded += ScheduleInsetRefresh;
        Canvas.RenderFailed += error => SetStatus(error.Message, error: true);
        Canvas.ImportFile += path => ImportFileRequested?.Invoke(path);
        Canvas.ImportBitmap += image => ImportBitmapRequested?.Invoke(image);
        Canvas.BackgroundDoubleClick += () => CopyImage(forceClose: true);
        Canvas.TextEditingChanged += active => { textEditingActive = active; if (!active) ScheduleInsetRefresh(); };
        Canvas.SelectionChanged += annotation =>
        {
            UpdateInspectorContext(annotation);
            if (annotation is null) return;
            annotationColor.Color = annotation.Color;
            Canvas.AnnotationColor = annotation.Color;
            Canvas.LineWidth = annotation.LineWidth;
            Canvas.TextSize = annotation.FontSize;
            syncing = true;
            var widthIndex = Array.IndexOf(Widths, annotation.LineWidth);
            foreach (var segment in widthSegments) segment.IsChecked = false;
            if (widthIndex >= 0) widthSegments[widthIndex].IsChecked = true;
            var fontIndex = Array.IndexOf(FontSizes, annotation.FontSize);
            fontPicker.SelectedIndex = fontIndex >= 0 ? fontIndex : 1;
            syncing = false;
        };
        PreviewKeyDown += OnPreviewKeyDown;
        Closing += (_, _) => OnClosing();
        Loaded += (_, _) => { Canvas.Focus(); };
        LoadBackground();
        LoadPresets();
        SetTool(EditorTool.Select);
        SyncInspector();
    }

    public EditState State => Canvas.State;
    internal Slider InspectorSlider(string key) => sliders[key].Slider;
    public bool CanUndo => history.CanUndo;

    // MARK: Interface

    private UIElement BuildInterface()
    {
        var root = new Grid();
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(60) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(1, GridUnitType.Star) });
        root.RowDefinitions.Add(new RowDefinition { Height = new GridLength(64) });

        // Header: identity on the left, Capture, Undo, Redo and More on the right.
        var header = new DockPanel { Margin = new Thickness(16, 0, 14, 0), LastChildFill = false };
        var icon = new Image { Source = UI.AppIcon(64), Width = 27, Height = 27, VerticalAlignment = VerticalAlignment.Center };
        var titles = new StackPanel { VerticalAlignment = VerticalAlignment.Center, Margin = new Thickness(10, 0, 0, 0) };
        titles.Children.Add(UI.Label("Velinshot", 13, FontWeights.SemiBold));
        var documentTitle = UI.Label(DocumentTitle, 11, secondary: true);
        documentTitle.MaxWidth = 260;
        titles.Children.Add(documentTitle);
        DockPanel.SetDock(icon, Dock.Left);
        DockPanel.SetDock(titles, Dock.Left);
        header.Children.Add(icon);
        header.Children.Add(titles);
        var capture = UI.Button("Capture", "capture", () => CaptureRequested?.Invoke(), tooltip: "New capture");
        AutomationProperties.SetName(capture, "New capture");
        undoButton = UI.Button(null, "undo", UndoEdit, tooltip: "Undo (Ctrl+Z)");
        redoButton = UI.Button(null, "redo", RedoEdit, tooltip: "Redo (Ctrl+Y or Ctrl+Shift+Z)");
        moreButton = UI.Button("More", "more", () => ShowMoreMenu(), tooltip: "Fit, copy image text, share, open, history and settings");
        AutomationProperties.SetName(moreButton, "More actions");
        var actions = new StackPanel { Orientation = Orientation.Horizontal, VerticalAlignment = VerticalAlignment.Center };
        foreach (var button in new[] { capture, undoButton, redoButton, moreButton }) { button.Margin = new Thickness(6, 0, 0, 0); actions.Children.Add(button); }
        DockPanel.SetDock(actions, Dock.Right);
        header.Children.Add(actions);
        var headerSurface = UI.Surface(header);
        Grid.SetRow(headerSurface, 0);
        root.Children.Add(headerSurface);

        // Content: tool rail, canvas, inspector.
        var content = new Grid();
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(64) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(1, GridUnitType.Star) });
        content.ColumnDefinitions.Add(new ColumnDefinition { Width = new GridLength(250) });
        var tools = new StackPanel { HorizontalAlignment = HorizontalAlignment.Center, Margin = new Thickness(0, 12, 0, 0) };
        AutomationProperties.SetName(tools, "Tools");
        foreach (var tool in RailTools)
        {
            var button = new ToggleButton { Content = Icons.Make(tool.Icon(), 20), ToolTip = tool.Title(), Margin = new Thickness(0, 0, 0, 4) };
            button.SetResourceReference(StyleProperty, "Studio.ToolButton");
            AutomationProperties.SetName(button, tool.Title());
            button.Click += (_, _) => SetTool(tool);
            toolButtons[tool] = button;
            tools.Children.Add(button);
        }
        var moreGlyph = new Grid { Width = 26, Height = 22 };
        moreGlyph.Children.Add(Icons.Make("more", 20));
        var chevron = Icons.Make("chevron-down", 9);
        chevron.HorizontalAlignment = HorizontalAlignment.Right;
        chevron.VerticalAlignment = VerticalAlignment.Bottom;
        chevron.Margin = new Thickness(0, 0, -4, -4);
        moreGlyph.Children.Add(chevron);
        moreToolsButton = new ToggleButton { Content = moreGlyph, ToolTip = "More tools: Draw, Line, Ellipse, Number, Blur" };
        moreToolsButton.SetResourceReference(StyleProperty, "Studio.ToolButton");
        AutomationProperties.SetName(moreToolsButton, "More tools");
        moreToolsButton.Click += (_, _) => ShowMoreToolsMenu();
        tools.Children.Add(moreToolsButton);
        var rail = UI.Surface(tools);
        Grid.SetColumn(rail, 0);
        content.Children.Add(rail);
        Grid.SetColumn(Canvas, 1);
        content.Children.Add(Canvas);
        var inspector = BuildInspector();
        Grid.SetColumn(inspector, 2);
        content.Children.Add(inspector);
        Grid.SetRow(content, 1);
        root.Children.Add(content);

        // Footer: information and Drag on the left; Save and Copy on the right.
        var footer = new DockPanel { Margin = new Thickness(18, 0, 16, 0), LastChildFill = false };
        dimensionsLabel.FontFamily = new FontFamily("Segoe UI Variable Text, Segoe UI");
        Typography.SetNumeralAlignment(dimensionsLabel, FontNumeralAlignment.Tabular);
        var information = new StackPanel { VerticalAlignment = VerticalAlignment.Center, MaxWidth = 300 };
        information.Children.Add(dimensionsLabel);
        information.Children.Add(statusLabel);
        statusLabel.Margin = new Thickness(0, 3, 0, 0);
        DockPanel.SetDock(information, Dock.Left);
        footer.Children.Add(information);
        var drag = UI.Button("Drag", "drag", () => SetStatus("Drag this button into another app or a folder."), tooltip: "Drag the finished image into another app or a folder", iconSize: 16);
        drag.Height = 32;
        drag.Margin = new Thickness(20, 0, 0, 0);
        drag.VerticalAlignment = VerticalAlignment.Center;
        drag.PreviewMouseLeftButtonDown += (_, e) => dragStart = e.GetPosition(this);
        drag.PreviewMouseMove += (_, e) => BeginDragExport(e);
        AutomationProperties.SetName(drag, "Drag screenshot");
        DockPanel.SetDock(drag, Dock.Left);
        footer.Children.Add(drag);
        var copy = UI.Button("Copy", "copy", () => CopyImage(), "Studio.PrimaryButton", "Copy and close (C or Ctrl+C)");
        copy.Width = 120;
        AutomationProperties.SetName(copy, "Copy screenshot");
        var save = UI.Button("Save", "save", () => SaveImage(), "Studio.SecondaryButton", "Choose where to save (S or Ctrl+S)");
        save.Width = 120;
        save.Margin = new Thickness(0, 0, 10, 0);
        AutomationProperties.SetName(save, "Save screenshot");
        DockPanel.SetDock(copy, Dock.Right);
        DockPanel.SetDock(save, Dock.Right);
        footer.Children.Add(copy);
        footer.Children.Add(save);
        var footerSurface = UI.Surface(footer);
        Grid.SetRow(footerSurface, 2);
        root.Children.Add(footerSurface);
        return root;
    }

    private static void Add(Panel panel, UIElement element, double top = 0)
    {
        if (element is FrameworkElement framework) framework.Margin = new Thickness(framework.Margin.Left, top, framework.Margin.Right, framework.Margin.Bottom);
        panel.Children.Add(element);
    }

    private FrameworkElement BuildInspector()
    {
        var top = new StackPanel { Margin = new Thickness(18, 16, 18, 0) };
        top.Children.Add(heading);
        var (track, segments) = UI.Segments(new[] { "Frame", "Backdrop", "Output" }, $"tabs{GetHashCode()}", index =>
        {
            if (syncing) return;
            ShowInspectorPage(index);
            Canvas.Focus();
        });
        tabs = track;
        tabSegments = segments;
        tabs.Margin = new Thickness(0, 10, 0, 0);
        AutomationProperties.SetName(tabs, "Inspector section");
        top.Children.Add(tabs);
        var stack = new StackPanel { Margin = new Thickness(18, 2, 18, 20) };
        inspectorScroll = new ScrollViewer { Content = stack, VerticalScrollBarVisibility = ScrollBarVisibility.Auto, HorizontalScrollBarVisibility = ScrollBarVisibility.Disabled, Margin = new Thickness(0, 12, 0, 0), Focusable = false };
        var panel = new DockPanel();
        DockPanel.SetDock(top, Dock.Top);
        panel.Children.Add(top);
        panel.Children.Add(inspectorScroll);

        // Markup: contextual controls for the active tool or selected mark.
        markupSection = new StackPanel { Visibility = Visibility.Collapsed };
        Add(markupSection, markupDescription);
        markupGuidance.TextWrapping = TextWrapping.Wrap;
        markupGuidance.TextTrimming = TextTrimming.None;
        Add(markupSection, markupGuidance, 8);
        annotationColor.Color = Canvas.AnnotationColor;
        annotationColor.ColorChanged += color => { Canvas.AnnotationColor = color; Canvas.ChangeSelection(color: color); };
        annotationColorRow = ColorRow("Color", annotationColor);
        Add(markupSection, annotationColorRow, 18);
        (widthTrack, var widths) = UI.Segments(new[] { "Thin", "Medium", "Bold" }, $"width{GetHashCode()}", index =>
        {
            if (syncing) return;
            Canvas.LineWidth = Widths[index];
            Canvas.ChangeSelection(lineWidth: Canvas.LineWidth);
        });
        widthSegments = widths;
        widths[1].IsChecked = true;
        AutomationProperties.SetName(widthTrack, "Annotation stroke width");
        Add(markupSection, widthTrack, 18);
        fontPicker = UI.Picker(FontSizes.Select(size => $"Text {size} px"), "Annotation text size");
        fontPicker.SelectedIndex = 1;
        fontPicker.SelectionChanged += (_, _) =>
        {
            if (syncing || fontPicker.SelectedIndex < 0) return;
            Canvas.TextSize = FontSizes[fontPicker.SelectedIndex];
            Canvas.ChangeSelection(fontSize: Canvas.TextSize);
        };
        Add(markupSection, fontPicker, 18);
        var back = UI.Button("Back to composition", "back", () => SetTool(EditorTool.Select), iconSize: 16);
        back.HorizontalAlignment = HorizontalAlignment.Left;
        back.Padding = new Thickness(6, 0, 10, 0);
        Add(markupSection, back, 14);
        stack.Children.Add(markupSection);

        // Frame
        var frame = new StackPanel();
        Add(frame, SliderRow("Padding", "padding", 0, 240));
        Add(frame, SliderRow("Corners", "cornerRadius", 0, 100), 10);
        Add(frame, SliderRow("Shadow", "shadow", 0, 100), 10);
        balanceCheck = UI.Check("Auto balance", Canvas.State.Style.AutoBalance, SetAutomaticBalance);
        balanceCheck.ToolTip = "Trim a uniform border around the screenshot";
        Add(frame, balanceCheck, 12);
        resetCropButton = UI.Button("Reset crop", "undo", () => { Change(s => { s.Crop = null; s.Style = s.Style with { AutoBalance = false }; }); Canvas.Fit(); }, iconSize: 16);
        resetCropButton.HorizontalAlignment = HorizontalAlignment.Left;
        resetCropButton.Padding = new Thickness(6, 0, 10, 0);
        Add(frame, resetCropButton, 6);
        advancedButton = UI.Button("Advanced frame", "chevron-right", () => SetAdvancedFrameExpanded(advancedSection.Visibility != Visibility.Visible), iconSize: 14);
        advancedButton.HorizontalAlignment = HorizontalAlignment.Left;
        advancedButton.Padding = new Thickness(6, 0, 10, 0);
        Add(frame, advancedButton, 2);
        advancedSection = new StackPanel();
        Add(advancedSection, SliderRow("Inset", "inset", 0, 160), 4);
        autoInsetCheck = UI.Check("Auto", Canvas.State.Style.AutoInsetColor, SetAutomaticInset);
        autoInsetCheck.ToolTip = "Follow the screenshot's dominant edge color";
        AutomationProperties.SetName(autoInsetCheck, "Automatic inset fill");
        insetColor.ColorChanged += color =>
        {
            CancelAnalysis();
            insetRefreshPending = false;
            preferences.AutoInsetFill = false;
            Change(s => s.Style = s.Style with { InsetColor = color, AutoInsetColor = false });
        };
        insetColor.Width = 140;
        var insetControls = new DockPanel { LastChildFill = false, Margin = new Thickness(0, 5, 0, 0) };
        DockPanel.SetDock(autoInsetCheck, Dock.Left);
        DockPanel.SetDock(insetColor, Dock.Right);
        insetControls.Children.Add(autoInsetCheck);
        insetControls.Children.Add(insetColor);
        Add(advancedSection, UI.Label("Inset fill", 13), 12);
        Add(advancedSection, insetControls);
        Add(advancedSection, SliderRow("Border", "borderWidth", 0, 12), 12);
        Add(frame, advancedSection);
        SetAdvancedFrameExpanded(false);

        // Backdrop
        var backdrop = new StackPanel();
        backgroundPicker = UI.Picker(new[] { "Gradient", "Solid color", "Image", "Transparent" }, "Background type");
        backgroundPicker.SelectionChanged += (_, _) => BackgroundChanged();
        Add(backdrop, backgroundPicker);
        var swatches = new StackPanel { Orientation = Orientation.Horizontal };
        foreach (var (name, first, second) in new[] { ("Iris", "B7AEF8", "E6E3FF"), ("Peach", "F5AF98", "F9E4BD"), ("Ocean", "92C6E9", "C4E4DC"), ("Ink", "292B3E", "54517B"), ("Paper", "F1EEE6", "FBFAF7") })
        {
            var swatch = new Button
            {
                Background = new LinearGradientBrush(Rgba.FromHex(first).ToColor(), Rgba.FromHex(second).ToColor(), 35),
                ToolTip = name, Margin = new Thickness(0, 0, 9, 0)
            };
            swatch.SetResourceReference(StyleProperty, "Studio.Swatch");
            AutomationProperties.SetName(swatch, $"{name} gradient");
            swatch.Click += (_, _) => Change(s => s.Style = s.Style with
            {
                Color1 = Rgba.FromHex(first), Color2 = Rgba.FromHex(second), Background = BackgroundKind.Gradient, AutoColor = false
            });
            swatches.Children.Add(swatch);
        }
        Add(backdrop, swatches, 16);
        firstColor.ColorChanged += color => Change(s => s.Style = s.Style with { Color1 = color, AutoColor = false });
        secondColor.ColorChanged += color => Change(s => s.Style = s.Style with { Color2 = color, AutoColor = false });
        Add(backdrop, ColorRow("First color", firstColor), 16);
        Add(backdrop, ColorRow("Second color", secondColor), 10);
        Add(backdrop, SliderRow("Gradient angle", "gradientAngle", 0, 360), 16);
        Add(backdrop, UI.Action("Choose background image…", "photo", ChooseBackground), 20);
        Add(backdrop, UI.Action("Use desktop wallpaper", "desktop", UseDesktopBackground), 8);
        autoColorCheck = UI.Check("Match image colors", Canvas.State.Style.AutoColor, SetAutomaticColors);
        Add(backdrop, autoColorCheck, 14);
        Add(backdrop, UI.Action("Balance & match", "wand", AutoBeautify), 10);

        // Output
        var output = new StackPanel();
        Add(output, UI.Caption("CANVAS"));
        ratioPicker = UI.Picker(Ratios.Select(r => r.Name).Append("Custom ratio or size…").Concat(Sizes.Select(s => s.Name)), "Canvas aspect ratio");
        ratioPicker.SelectionChanged += (_, _) => RatioChanged();
        Add(output, ratioPicker, 8);
        scalePicker = UI.Picker(new[] { "1×  Original pixels", "2×  Double pixels", "½×  Smaller image", "Set output width…" }, "Output scale");
        scalePicker.SelectionChanged += (_, _) => ScaleChanged();
        Add(output, scalePicker, 10);
        Add(output, UI.Caption("WATERMARK"), 22);
        AutomationProperties.SetName(watermarkField, "Optional watermark text");
        watermarkField.ToolTip = "Optional text";
        watermarkField.MaxLength = 512;
        watermarkField.GotKeyboardFocus += (_, _) => { watermarkGestureBefore = Canvas.State.Clone(); textEditingActive = true; };
        watermarkField.LostKeyboardFocus += (_, _) =>
        {
            textEditingActive = false;
            if (watermarkGestureBefore is { } before) { watermarkGestureBefore = null; Commit(before, Canvas.State.Clone()); }
        };
        watermarkField.TextChanged += (_, _) =>
        {
            if (syncing) return;
            var text = watermarkField.Text;
            Change(s => s.Style = s.Style with { WatermarkText = text });
        };
        Add(output, watermarkField, 8);
        watermarkPosition = UI.Picker(new[] { "Top left", "Top right", "Bottom left", "Bottom right" }, "Watermark position");
        watermarkPosition.SelectionChanged += (_, _) =>
        {
            if (syncing || watermarkPosition.SelectedIndex < 0) return;
            Change(s => s.Style = s.Style with { WatermarkPosition = (WatermarkPosition)watermarkPosition.SelectedIndex });
        };
        Add(output, watermarkPosition, 10);
        watermarkColor.ColorChanged += color => Change(s => s.Style = s.Style with { WatermarkColor = color });
        Add(output, ColorRow("Text color", watermarkColor), 10);
        Add(output, UI.Caption("SAVED STYLES"), 22);
        presetPicker = UI.Picker(Array.Empty<string>(), "Saved frame preset");
        presetPicker.SelectionChanged += (_, _) => PresetChanged();
        Add(output, presetPicker, 8);
        Add(output, UI.Action("Save current style…", "plus", SavePreset), 10);
        Add(output, UI.Action("Delete selected preset", "minus", DeletePreset), 8);

        foreach (var page in new[] { frame, backdrop, output }) { pages.Add(page); stack.Children.Add(page); }
        tabSegments[0].IsChecked = true;
        ShowInspectorPage(0);
        return UI.Surface(panel);
    }

    private static FrameworkElement ColorRow(string title, ColorButton well)
    {
        var row = new DockPanel { LastChildFill = false };
        var label = UI.Label(title);
        DockPanel.SetDock(label, Dock.Left);
        DockPanel.SetDock(well, Dock.Right);
        well.MinWidth = 104;
        row.Children.Add(label);
        row.Children.Add(well);
        return row;
    }

    private FrameworkElement SliderRow(string title, string key, double minimum, double maximum)
    {
        var value = UI.Label("", 11, secondary: true);
        Typography.SetNumeralAlignment(value, FontNumeralAlignment.Tabular);
        var top = new DockPanel { LastChildFill = false };
        var label = UI.Label(title);
        DockPanel.SetDock(label, Dock.Left);
        DockPanel.SetDock(value, Dock.Right);
        top.Children.Add(label);
        top.Children.Add(value);
        var slider = new Slider { Minimum = minimum, Maximum = maximum, SmallChange = 1, LargeChange = 10, IsMoveToPointEnabled = true, Margin = new Thickness(0, 4, 0, 0) };
        AutomationProperties.SetName(slider, title);
        slider.AddHandler(Thumb.DragStartedEvent, new DragStartedEventHandler((_, _) => { Canvas.FinishText(); inspectorGestureBefore = Canvas.State.Clone(); }));
        slider.AddHandler(Thumb.DragCompletedEvent, new DragCompletedEventHandler((_, _) =>
        {
            if (inspectorGestureBefore is not { } before) return;
            inspectorGestureBefore = null;
            Commit(before, Canvas.State.Clone());
            ScheduleInsetRefresh();
        }));
        slider.ValueChanged += (_, _) =>
        {
            if (syncing) return;
            var rounded = Math.Round(slider.Value);
            Change(s => s.Style = key switch
            {
                "padding" => s.Style with { Padding = rounded },
                "inset" => s.Style with { Inset = rounded },
                "cornerRadius" => s.Style with { CornerRadius = rounded },
                "shadow" => s.Style with { Shadow = rounded },
                "borderWidth" => s.Style with { BorderWidth = rounded },
                "gradientAngle" => s.Style with { GradientAngle = rounded },
                _ => s.Style
            });
        };
        sliders[key] = (slider, value);
        var group = new StackPanel();
        group.Children.Add(top);
        group.Children.Add(slider);
        return group;
    }

    private void ShowInspectorPage(int index)
    {
        for (var i = 0; i < pages.Count; i++) pages[i].Visibility = i == index && markupSection.Visibility != Visibility.Visible ? Visibility.Visible : Visibility.Collapsed;
        inspectorScroll.ScrollToTop();
    }

    public void ShowInspectorSection(int index)
    {
        if (index < 0 || index >= pages.Count) return;
        SetTool(EditorTool.Select);
        syncing = true;
        tabSegments[index].IsChecked = true;
        syncing = false;
        ShowInspectorPage(index);
    }

    private int SelectedPage => Array.FindIndex(tabSegments, s => s.IsChecked == true) is var index and >= 0 ? index : 0;

    private void SetAdvancedFrameExpanded(bool expanded)
    {
        if (!expanded && advancedSection.IsKeyboardFocusWithin) advancedButton.Focus();
        advancedSection.Visibility = expanded ? Visibility.Visible : Visibility.Collapsed;
        advancedButton.Content = UI.Content(expanded ? "chevron-down" : "chevron-right", "Advanced frame", 14);
        advancedButton.ToolTip = expanded ? "Hide inset and border options" : "Show inset and border options";
        AutomationProperties.SetItemStatus(advancedButton, expanded ? "Expanded" : "Collapsed");
    }

    // MARK: Tools

    public void SetTool(EditorTool tool)
    {
        Canvas.FinishText();
        Canvas.FinishPointerGesture();
        Canvas.Tool = tool;
        UpdateInspectorContext(null);
        inspectorScroll.ScrollToTop();
        foreach (var (kind, button) in toolButtons) button.IsChecked = kind == tool;
        var secondary = SecondaryTools.Contains(tool);
        moreToolsButton.IsChecked = secondary;
        AutomationProperties.SetItemStatus(moreToolsButton, secondary ? $"{tool.Title()} selected" : "No secondary tool selected");
        moreToolsButton.ToolTip = secondary ? $"More tools · {tool.Title()}" : "More tools: Draw, Line, Ellipse, Number, Blur";
        Canvas.Focus();
        SetStatus(tool.Title());
    }

    private void ShowMoreToolsMenu()
    {
        moreToolsButton.IsChecked = SecondaryTools.Contains(Canvas.Tool);
        var menu = new ContextMenu { PlacementTarget = moreToolsButton, Placement = PlacementMode.Right };
        foreach (var tool in SecondaryTools)
        {
            var item = new MenuItem { Header = tool.Title(), Icon = Icons.Make(tool.Icon(), 16), IsCheckable = true, IsChecked = Canvas.Tool == tool };
            item.Click += (_, _) => SetTool(tool);
            menu.Items.Add(item);
        }
        menu.IsOpen = true;
    }

    private void ShowMoreMenu()
    {
        var menu = new ContextMenu { PlacementTarget = moreButton, Placement = PlacementMode.Bottom };
        void Item(string header, string? icon, string? gesture, Action action)
        {
            var item = new MenuItem { Header = header, InputGestureText = gesture ?? "" };
            if (icon is not null) item.Icon = Icons.Make(icon, 16);
            item.Click += (_, _) => action();
            menu.Items.Add(item);
        }
        Item("Fit to Preview", "fit", "Ctrl+0", () => { Canvas.Fit(); Canvas.Focus(); });
        Item("Copy Image Text…", "text-scan", null, RecognizeText);
        Item("Share Screenshot…", "share", null, ShareScreenshot);
        menu.Items.Add(new Separator());
        Item("Copy Original", "copy", null, () => CopyImage(original: true));
        Item("Save Original…", "save", null, () => SaveImage(original: true));
        menu.Items.Add(new Separator());
        Item("Open Image…", "open", "Ctrl+O", () => OpenRequested?.Invoke());
        Item("Open from Clipboard", "clipboard", "Ctrl+V", () => PasteRequested?.Invoke());
        Item("Reopen Closed Screenshot", null, "Ctrl+Shift+T", () => ReopenRequested?.Invoke());
        Item("Screenshot History…", "clock", null, () => HistoryRequested?.Invoke());
        menu.Items.Add(new Separator());
        Item("Settings…", "settings", null, () => SettingsRequested?.Invoke());
        Item("Keyboard Shortcuts", null, null, () => ShortcutsRequested?.Invoke());
        Item("Open Demo Image", null, null, () => DemoRequested?.Invoke());
        Item("Check for Updates…", null, null, () => UpdatesRequested?.Invoke());
        Item("About Velinshot", null, null, () => AboutRequested?.Invoke());
        menu.IsOpen = true;
    }

    private void UpdateInspectorContext(Annotation? annotation)
    {
        var active = annotation is not null || Canvas.Tool is not (EditorTool.Select or EditorTool.Crop);
        markupSection.Visibility = active ? Visibility.Visible : Visibility.Collapsed;
        tabs.Visibility = active ? Visibility.Collapsed : Visibility.Visible;
        heading.Text = active ? "Markup" : "Composition";
        ShowInspectorPage(SelectedPage);
        var kind = annotation?.Kind ?? Canvas.Tool.Kind();
        markupDescription.Text = kind?.ToString() ?? Canvas.Tool.ToString();
        var blur = kind == AnnotationKind.Blur;
        annotationColorRow.Visibility = blur ? Visibility.Collapsed : Visibility.Visible;
        markupGuidance.Visibility = blur ? Visibility.Visible : Visibility.Collapsed;
        markupGuidance.Text = annotation is null ? "Drag over the image to blur an area." : "Adjust strength below, or move and resize the selected area.";
        fontPicker.Visibility = kind is AnnotationKind.Text or AnnotationKind.Number ? Visibility.Visible : Visibility.Collapsed;
        var track = widthTrack;
        track.Visibility = kind is AnnotationKind.Text or AnnotationKind.Number or AnnotationKind.Redact ? Visibility.Collapsed : Visibility.Visible;
        var labels = blur ? new[] { "Soft", "Medium", "Strong" } : new[] { "Thin", "Medium", "Bold" };
        for (var i = 0; i < labels.Length; i++) widthSegments[i].Content = labels[i];
        AutomationProperties.SetName(track, blur ? "Blur strength" : "Annotation stroke width");
    }

    // MARK: State and undo

    private void Commit(EditState before, EditState after)
    {
        if (before.ContentEquals(after)) return;
        history.Record(before, after);
        StoreStyle(after.Style, before.Style);
        SyncInspector();
        UpdateInsetRequest(before, after);
    }

    private void Restore(EditState target)
    {
        CancelAnalysis();
        var previous = Canvas.State;
        var restored = target.Clone();
        if (restored.Style.AutoInsetColor && Nullable.Equals(analysis.InsetCrop, restored.Crop) && analysis.InsetColor is { } color)
            restored.Style = restored.Style with { InsetColor = color };
        Canvas.State = restored;
        StoreStyle(restored.Style, previous.Style);
        Canvas.ClearSelection();
        LoadBackground();
        SyncInspector();
        UpdateInsetRequest(previous, restored);
    }

    /// <summary>Applies an inspector change. While a slider or the watermark field is mid-gesture,
    /// one undo step is recorded when the gesture ends.</summary>
    private void Change(Action<EditState> mutation)
    {
        Canvas.FinishText();
        Canvas.FinishPointerGesture();
        var before = Canvas.State.Clone();
        var after = before.Clone();
        mutation(after);
        try { CanvasRenderer.Layout(new Size(Source.PixelWidth, Source.PixelHeight), after); }
        catch (Exception error) { SetStatus(error.Message, error: true); SyncInspector(); return; }
        Canvas.State = after;
        if (inspectorGestureBefore is null && watermarkGestureBefore is null) Commit(before, after.Clone()); else SyncInspector();
    }

    private void StoreStyle(CanvasStyle style, CanvasStyle previous)
    {
        var automatic = preferences.AutoInsetFill;
        var stored = style;
        if (!automatic && style.AutoInsetColor && style.AutoInsetColor == previous.AutoInsetColor)
            stored = stored with { InsetColor = preferences.Style.InsetColor };
        preferences.Style = stored;
        if (style.AutoInsetColor == previous.AutoInsetColor) preferences.AutoInsetFill = automatic;
    }

    public void UndoEdit()
    {
        Canvas.FinishText();
        if (!Canvas.CancelPointerGesture() && history.Undo() is { } state) Restore(state);
        SyncInspector();
    }

    public void RedoEdit()
    {
        Canvas.FinishText();
        if (!Canvas.CancelPointerGesture() && history.Redo() is { } state) Restore(state);
        SyncInspector();
    }

    private void SyncInspector()
    {
        syncing = true;
        try
        {
            var style = Canvas.State.Style;
            resetCropButton.IsEnabled = Canvas.State.Crop is not null;
            undoButton.IsEnabled = history.CanUndo;
            redoButton.IsEnabled = history.CanRedo;
            var values = new Dictionary<string, double>
            {
                ["padding"] = style.Padding, ["inset"] = style.Inset, ["cornerRadius"] = style.CornerRadius, ["shadow"] = style.Shadow,
                ["borderWidth"] = style.BorderWidth, ["gradientAngle"] = style.GradientAngle
            };
            foreach (var (key, value) in values)
            {
                if (!sliders.TryGetValue(key, out var row)) continue;
                row.Slider.Value = value;
                row.Value.Text = key == "gradientAngle" ? $"{(int)value}°" : $"{(int)value} px";
            }
            backgroundPicker.SelectedIndex = style.Background switch
            {
                BackgroundKind.Gradient => 0, BackgroundKind.Solid => 1, BackgroundKind.Image => 2, _ => 3
            };
            firstColor.Color = style.Color1;
            secondColor.Color = style.Color2;
            insetColor.Color = style.InsetColor;
            balanceCheck.IsChecked = style.AutoBalance;
            autoColorCheck.IsChecked = style.AutoColor;
            autoInsetCheck.IsChecked = style.AutoInsetColor;
            if (style is { FixedWidth: { } width, FixedHeight: { } height })
            {
                var size = Array.FindIndex(Sizes, s => s.Width == width && s.Height == height);
                ratioPicker.SelectedIndex = size >= 0 ? Ratios.Length + 1 + size : Ratios.Length;
                scalePicker.SelectedIndex = 3;
            }
            else
            {
                var ratio = Array.FindIndex(Ratios, r => Math.Abs(r.Width - style.RatioWidth) < 0.001 && Math.Abs(r.Height - style.RatioHeight) < 0.001);
                ratioPicker.SelectedIndex = ratio >= 0 ? ratio : Ratios.Length;
                scalePicker.SelectedIndex = Math.Abs(style.OutputScale - 1) < 0.001 ? 0 : Math.Abs(style.OutputScale - 2) < 0.001 ? 1 : Math.Abs(style.OutputScale - 0.5) < 0.001 ? 2 : 3;
            }
            if (watermarkField.Text != style.WatermarkText) watermarkField.Text = style.WatermarkText;
            watermarkPosition.SelectedIndex = (int)style.WatermarkPosition;
            watermarkColor.Color = style.WatermarkColor;
            try
            {
                var layout = CanvasRenderer.Layout(new Size(Source.PixelWidth, Source.PixelHeight), Canvas.State);
                dimensionsLabel.Text = $"{(int)layout.ExportSize.Width} × {(int)layout.ExportSize.Height} px";
            }
            catch (Exception) { /* The status line already explains an invalid state. */ }
        }
        finally { syncing = false; }
    }

    // MARK: Inspector handlers

    private void BackgroundChanged()
    {
        if (syncing || backgroundPicker.SelectedIndex < 0) return;
        var kinds = new[] { BackgroundKind.Gradient, BackgroundKind.Solid, BackgroundKind.Image, BackgroundKind.Transparent };
        var kind = kinds[backgroundPicker.SelectedIndex];
        Change(s => s.Style = s.Style with { Background = kind, AutoColor = false });
        if (kind == BackgroundKind.Image && Canvas.BackgroundImage is null) Dispatcher.BeginInvoke(ChooseBackground);
    }

    private void RatioChanged()
    {
        if (syncing || ratioPicker.SelectedIndex < 0) return;
        var index = ratioPicker.SelectedIndex;
        if (index < Ratios.Length)
        {
            var ratio = Ratios[index];
            Change(s => s.Style = s.Style with { RatioWidth = ratio.Width, RatioHeight = ratio.Height, FixedWidth = null, FixedHeight = null });
            Canvas.Fit();
            return;
        }
        if (index > Ratios.Length)
        {
            var size = Sizes[index - Ratios.Length - 1];
            SetFixedSize(size.Width, size.Height);
            return;
        }
        Dispatcher.BeginInvoke(() =>
        {
            if (Dialogs.Ask(this, "Custom canvas", "Enter a ratio (3:2) or an exact size in pixels (1920x1080).", "1920x1080") is not { } result) { SyncInspector(); return; }
            var sizeParts = result.ToLowerInvariant().Replace('×', 'x').Split('x', StringSplitOptions.TrimEntries)
                .Select(part => int.TryParse(part, out var number) ? number : (int?)null).ToArray();
            if (sizeParts.Length == 2 && sizeParts.All(p => p.HasValue)) { SetFixedSize(sizeParts[0]!.Value, sizeParts[1]!.Value); return; }
            var parts = result.Split(':', StringSplitOptions.TrimEntries)
                .Select(part => double.TryParse(part, System.Globalization.NumberStyles.Float, System.Globalization.CultureInfo.InvariantCulture, out var number) ? number : double.NaN).ToArray();
            if (parts.Length != 2 || parts.Any(p => !double.IsFinite(p) || p <= 0 || p > 1000))
            {
                SetStatus("Enter a ratio such as 3:2.", error: true);
                SyncInspector();
                return;
            }
            Change(s => s.Style = s.Style with { RatioWidth = parts[0], RatioHeight = parts[1], FixedWidth = null, FixedHeight = null });
            Canvas.Fit();
        });
    }

    private void SetFixedSize(int width, int height)
    {
        if (width <= 0 || height <= 0 || width > 16384 || height > 16384 || (long)width * height > 40_000_000)
        {
            SetStatus("Choose dimensions up to 40 megapixels and 16384 px per side.", error: true);
            SyncInspector();
            return;
        }
        double maximum = Math.Max(width, height);
        Change(s => s.Style = s.Style with { FixedWidth = width, FixedHeight = height, RatioWidth = width / maximum * 1000, RatioHeight = height / maximum * 1000 });
        Canvas.Fit();
    }

    private void ScaleChanged()
    {
        if (syncing || scalePicker.SelectedIndex < 0) return;
        if (scalePicker.SelectedIndex < 3)
        {
            var scale = new[] { 1.0, 2, 0.5 }[scalePicker.SelectedIndex];
            Change(s => s.Style = s.Style with { OutputScale = scale, FixedWidth = null, FixedHeight = null });
            return;
        }
        Dispatcher.BeginInvoke(() =>
        {
            if (Dialogs.Ask(this, "Output width", "Enter the final width in pixels. Height follows the canvas ratio.", "1920") is not { } input ||
                !double.TryParse(input, out var width) || !double.IsFinite(width) || width <= 0 || width > 16384)
            {
                SyncInspector();
                return;
            }
            try
            {
                var layout = CanvasRenderer.Layout(new Size(Source.PixelWidth, Source.PixelHeight), Canvas.State);
                SetFixedSize((int)Math.Round(width), Math.Max(1, (int)Math.Round(width / layout.CanvasSize.Width * layout.CanvasSize.Height)));
            }
            catch (Exception) { SyncInspector(); }
        });
    }

    // MARK: Automatic balance, colors and inset fill

    private void SetAutomaticBalance(bool enabled)
    {
        if (enabled) RequestAnalysis(balance: true, colors: false);
        else { CancelAnalysis(); Change(s => { s.Style = s.Style with { AutoBalance = false }; s.Crop = null; }); Canvas.Fit(); }
    }

    private void SetAutomaticColors(bool enabled)
    {
        if (enabled) RequestAnalysis(balance: false, colors: true);
        else { CancelAnalysis(); Change(s => s.Style = s.Style with { AutoColor = false }); }
    }

    private void CancelAnalysis()
    {
        if (analysisWork.IsBusy && insetJobCrop is null) SetStatus("Ready");
        analysisWork.Cancel();
        insetJobCrop = null;
        ScheduleInsetRefresh();
    }

    private void SetAutomaticInset(bool enabled)
    {
        CancelAnalysis();
        insetRefreshPending = enabled;
        preferences.AutoInsetFill = enabled;
        Change(s => s.Style = s.Style with { AutoInsetColor = enabled });
        ScheduleInsetRefresh();
    }

    private void UpdateInsetRequest(EditState before, EditState after)
    {
        if (!after.Style.AutoInsetColor) { insetRefreshPending = false; return; }
        if (!Nullable.Equals(before.Crop, after.Crop) || !before.Style.AutoInsetColor || before.Style.InsetColor != after.Style.InsetColor)
            insetRefreshPending = true;
        ScheduleInsetRefresh();
    }

    private void ScheduleInsetRefresh()
    {
        if (!insetRefreshPending || insetRefreshScheduled || userIsClosing) return;
        insetRefreshScheduled = true;
        Dispatcher.BeginInvoke(() => { insetRefreshScheduled = false; RefreshInsetIfReady(); });
    }

    /// <summary>Automatic inset fill follows the visible image's edge palette, re-analyzed after
    /// crops, and never mid-gesture.</summary>
    private void RefreshInsetIfReady()
    {
        if (!insetRefreshPending || userIsClosing || !Canvas.State.Style.AutoInsetColor) return;
        if (Canvas.HasActiveGesture || inspectorGestureBefore is not null || watermarkGestureBefore is not null) return;
        var crop = Canvas.State.Crop;
        if (Nullable.Equals(analysis.InsetCrop, crop) && analysis.InsetColor is { } color)
        {
            insetRefreshPending = false;
            if (Canvas.State.Style.InsetColor != color)
            {
                var updated = Canvas.State.Clone();
                updated.Style = updated.Style with { InsetColor = color };
                Canvas.State = updated;
                StoreStyle(updated.Style, updated.Style);
                SyncInspector();
            }
            return;
        }
        if (insetJobCrop is { } pending && Nullable.Equals(pending.Bounds, crop)) return;
        if (analysisWork.IsBusy) return;
        var source = Source;
        var cached = analysis;
        insetJobCrop = new KnownContentBounds(crop);
        analysisWork.Submit(() => cached with { InsetColor = Core.AutoBeautify.SuggestInsetColor(source, crop), InsetCrop = crop }, value =>
        {
            if (userIsClosing) return;
            insetJobCrop = null;
            analysis = analysis with { InsetColor = value.InsetColor, InsetCrop = value.InsetCrop };
            if (Canvas.State.Style.AutoInsetColor && Nullable.Equals(Canvas.State.Crop, crop)) insetRefreshPending = true;
            ScheduleInsetRefresh();
        }, error =>
        {
            insetJobCrop = null;
            insetRefreshPending = false;
            ShowError(error);
        });
    }

    private void AutoBeautify() => RequestAnalysis(balance: true, colors: true);

    private void RequestAnalysis(bool balance, bool colors)
    {
        Canvas.Focus();
        Canvas.FinishText();
        var before = Canvas.State.Clone();
        var source = Source;
        var cached = analysis;
        insetJobCrop = null;
        SetStatus(balance ? "Balancing your image…" : "Matching image colors…");
        analysisWork.Submit(() =>
        {
            var result = cached;
            if (balance && result.Bounds is null) result = result with { Bounds = new KnownContentBounds(Core.AutoBeautify.ContentBounds(source)) };
            if (colors && result.Colors is null) result = result with { Colors = Core.AutoBeautify.SuggestColors(source) };
            if (balance && before.Style.AutoInsetColor)
            {
                var crop = result.Bounds?.Bounds;
                if (result.InsetColor is null || !Nullable.Equals(result.InsetCrop, crop))
                    result = result with { InsetColor = Core.AutoBeautify.SuggestInsetColor(source, crop), InsetCrop = crop };
            }
            return result;
        }, value =>
        {
            if (userIsClosing) return;
            analysis = value;
            if (!CanInstallAnalysis(before)) { SyncInspector(); SetStatus("Image changed. Choose balance again when ready."); ScheduleInsetRefresh(); return; }
            Change(s =>
            {
                if (balance) { s.Crop = value.Bounds?.Bounds; s.Style = s.Style with { AutoBalance = true }; }
                if (colors && value.Colors is { } pair) s.Style = s.Style with { Color1 = pair.First, Color2 = pair.Second, Background = BackgroundKind.Gradient, AutoColor = true };
                if (balance && s.Style.AutoInsetColor && value.InsetColor is { } inset) s.Style = s.Style with { InsetColor = inset };
            });
            Canvas.Fit();
            SetStatus(balance && colors ? "Balanced and matched to your image" : balance ? "Image balanced" : "Colors matched");
            ScheduleInsetRefresh();
        }, error => { SyncInspector(); ShowError(error); ScheduleInsetRefresh(); });
    }

    private bool CanInstallAnalysis(EditState state) =>
        Canvas.State.ContentEquals(state) && !Canvas.HasActiveGesture && inspectorGestureBefore is null && watermarkGestureBefore is null && !userIsClosing;

    // MARK: Backgrounds

    private string BackgroundsDirectory => Path.Combine(AppSettings.SupportDirectory, "Backgrounds");

    private void ChooseBackground()
    {
        var dialog = new Microsoft.Win32.OpenFileDialog { Title = "Choose a background image", Filter = ImageFilter };
        if (dialog.ShowDialog(this) == true) SetBackground(dialog.FileName);
        else SyncInspector();
    }

    public const string ImageFilter = "Images|*.png;*.jpg;*.jpeg;*.bmp;*.gif;*.tif;*.tiff;*.webp;*.heic;*.jxr|All files|*.*";

    private void SetBackground(string path, bool wallpaper = false)
    {
        var directory = BackgroundsDirectory;
        var before = Canvas.State.Style;
        SetStatus("Opening background…");
        pendingBackgroundId = null;
        backgroundWork.Submit(() =>
        {
            var image = ImageLoader.Load(path);
            var data = ImageExporter.Data(image, ImageFormat.Png);
            Directory.CreateDirectory(directory);
            var id = Guid.NewGuid().ToString("D").ToUpperInvariant();
            File.WriteAllBytes(Path.Combine(directory, id + ".png"), data);
            return (image, id);
        }, result =>
        {
            if (userIsClosing || Canvas.State.Style != before) return;
            loadedBackgroundId = result.Id;
            Change(s => s.Style = s.Style with { Background = BackgroundKind.Image, BackgroundAssetId = result.Id, AutoColor = false });
            Canvas.BackgroundImage = result.Image;
            SetStatus("Background ready");
        }, error =>
        {
            if (wallpaper)
            {
                Change(s => s.Style = s.Style with { Background = BackgroundKind.Gradient });
                SetStatus("Wallpaper unavailable. Using the gradient; choose an image instead.", error: true);
            }
            else ShowError(error);
        });
    }

    private void UseDesktopBackground()
    {
        if (ScreenCapture.DesktopWallpaperPath() is not { } path)
        {
            Change(s => s.Style = s.Style with { Background = BackgroundKind.Gradient });
            SetStatus("Wallpaper unavailable. Choose a background image instead.", error: true);
            return;
        }
        SetBackground(path, wallpaper: true);
    }

    private void LoadBackground()
    {
        if (Canvas.State.Style.BackgroundAssetId is not { } id || !Guid.TryParse(id, out _))
        {
            backgroundWork.Cancel();
            pendingBackgroundId = null;
            loadedBackgroundId = null;
            if (Canvas.BackgroundImage is not null) Canvas.BackgroundImage = null;
            return;
        }
        if (loadedBackgroundId == id && Canvas.BackgroundImage is not null) return;
        if (pendingBackgroundId == id && backgroundWork.IsBusy) return;
        var path = Path.Combine(BackgroundsDirectory, id + ".png");
        pendingBackgroundId = id;
        backgroundWork.Submit(() => (ImageLoader.Load(path), id), result =>
        {
            if (userIsClosing || Canvas.State.Style.BackgroundAssetId != id) return;
            pendingBackgroundId = null;
            loadedBackgroundId = result.Id;
            Canvas.BackgroundImage = result.Image;
        }, _ =>
        {
            if (userIsClosing || Canvas.State.Style.BackgroundAssetId != id) return;
            pendingBackgroundId = null;
            loadedBackgroundId = null;
            Canvas.BackgroundImage = null;
            SetStatus("Background image is missing. Choose it again.", error: true);
        });
    }

    // MARK: Presets

    private void LoadPresets()
    {
        try { presets = presetStore.Load(); }
        catch (Exception error) { presets = new(); SetStatus($"Could not read presets: {error.Message}", error: true); }
        syncing = true;
        presetPicker.Items.Clear();
        presetPicker.Items.Add("Choose a saved style…");
        foreach (var preset in presets) presetPicker.Items.Add(preset.Name);
        presetPicker.SelectedIndex = 0;
        syncing = false;
    }

    private void PresetChanged()
    {
        if (syncing) return;
        var index = presetPicker.SelectedIndex - 1;
        if (index < 0 || index >= presets.Count) return;
        var style = presets[index].Style;
        preferences.AutoInsetFill = style.AutoInsetColor;
        Change(s => s.Style = style);
        LoadBackground();
        Canvas.Fit();
    }

    private void SavePreset()
    {
        if (Dialogs.Ask(this, "Save frame preset", "Your background, inset, corners, shadow and canvas settings will be saved.", "My style") is not { } name ||
            string.IsNullOrWhiteSpace(name)) return;
        name = name.Trim();
        var existing = presets.FindIndex(p => p.Name == name);
        if (existing >= 0) presets[existing].Style = Canvas.State.Style;
        else presets.Add(new StylePreset { Name = name, Style = Canvas.State.Style });
        try { presetStore.Save(presets); LoadPresets(); SetStatus("Preset saved"); }
        catch (Exception error) { ShowError(error); }
    }

    private void DeletePreset()
    {
        var index = presetPicker.SelectedIndex - 1;
        if (index < 0 || index >= presets.Count) { SetStatus("Choose a saved preset first"); return; }
        presets.RemoveAt(index);
        try { presetStore.Save(presets); LoadPresets(); SetStatus("Preset deleted"); }
        catch (Exception error) { ShowError(error); }
    }

    // MARK: Export

    /// <summary>Renders the finished image at full resolution off the UI thread.</summary>
    public Task<BitmapSource> RenderedImageAsync()
    {
        Canvas.FinishText();
        Canvas.FinishPointerGesture();
        var state = Canvas.State.Clone();
        var background = Canvas.BackgroundImage;
        var source = Source;
        return StaWorker.Work.Run(() => CanvasRenderer.Render(source, state, background));
    }

    public async void CopyImage(bool original = false, bool forceClose = false)
    {
        if (busyExporting) return;
        busyExporting = true;
        try
        {
            SetStatus("Copying…");
            var image = original ? Source : await RenderedImageAsync();
            if (!ClipboardExport.Copy(image)) { SetStatus("The clipboard is busy. Try copying again.", error: true); return; }
            var historyOk = PersistHistory();
            Sound.Play(preferences);
            if (!historyOk) { SetStatus($"Copied. History not saved: {historyFailure ?? "Choose another history folder in Settings."}", error: true); return; }
            SetStatus("Copied to clipboard");
            if (forceClose || preferences.CloseAfterCopy) Close();
        }
        catch (Exception error) { ShowError(error); }
        finally { busyExporting = false; }
    }

    public async void SaveImage(bool original = false)
    {
        if (busyExporting) return;
        busyExporting = true;
        try
        {
            Canvas.FinishText();
            Canvas.FinishPointerGesture();
            var safeName = string.Concat((preferences.Filename.Length == 0 ? "Screenshot" : preferences.Filename).Select(c => Path.GetInvalidFileNameChars().Contains(c) ? '-' : c));
            var dialog = new Microsoft.Win32.SaveFileDialog
            {
                Title = "Save screenshot", Filter = "PNG image (lossless)|*.png|JPEG image (smaller)|*.jpg",
                FilterIndex = preferences.JpegByDefault ? 2 : 1, AddExtension = true, OverwritePrompt = true,
                InitialDirectory = preferences.SaveDirectory,
                FileName = $"{safeName} {DateTime.Now:yyyy-MM-dd 'at' HH.mm.ss}"
            };
            if (dialog.ShowDialog(this) != true) { SetStatus("Save cancelled"); return; }
            var path = dialog.FileName;
            var format = ImageFormats.ForPath(path, dialog.FilterIndex == 2 ? ImageFormat.Jpeg : ImageFormat.Png);
            SetStatus("Saving…");
            var image = original ? Source : await RenderedImageAsync();
            var quality = preferences.Quality;
            var data = await StaWorker.Work.Run(() => ImageExporter.Data(image, format, quality));
            await File.WriteAllBytesAsync(path, data);
            preferences.SaveDirectory = Path.GetDirectoryName(path)!;
            preferences.JpegByDefault = format == ImageFormat.Jpeg;
            var historyOk = PersistHistory();
            Sound.Play(preferences);
            SetStatus(historyOk ? $"Saved {Path.GetFileName(path)}" : $"Saved file. History not saved: {historyFailure ?? "Choose another folder in Settings."}", error: !historyOk);
        }
        catch (Exception error) { ShowError(error); }
        finally { busyExporting = false; }
    }

    private void BeginDragExport(MouseEventArgs e)
    {
        if (dragStart is not { } start || e.LeftButton != MouseButtonState.Pressed) return;
        var delta = e.GetPosition(this) - start;
        if (Math.Abs(delta.X) < SystemParameters.MinimumHorizontalDragDistance && Math.Abs(delta.Y) < SystemParameters.MinimumVerticalDragDistance) return;
        dragStart = null;
        try
        {
            Canvas.FinishText();
            Canvas.FinishPointerGesture();
            // Drag must start synchronously, so this one render runs on the UI thread.
            var image = CanvasRenderer.Render(Source, Canvas.State.Clone(), Canvas.BackgroundImage);
            var data = ClipboardExport.DragData(image, DocumentTitle);
            DragDrop.DoDragDrop((DependencyObject)e.Source, data, DragDropEffects.Copy);
            PersistHistory();
        }
        catch (Exception error) { ShowError(error); }
    }

    private async void ShareScreenshot()
    {
        try
        {
            var image = await RenderedImageAsync();
            await ShareExport.ShowAsync(new WindowInteropHelper(this).Handle, image, DocumentTitle);
        }
        catch (Exception error) { ShowError(error); }
    }

    public bool PersistHistory()
    {
        historyFailure = null;
        if (!preferences.HistoryEnabled) return true;
        try
        {
            var store = new HistoryStore(preferences.HistoryDirectory);
            if (HistoryEntry is { } entry) store.Update(entry, Canvas.State);
            else HistoryEntry = store.Save(Source, Canvas.State);
            return true;
        }
        catch (Exception error)
        {
            historyFailure = error.Message;
            SetStatus($"History could not be saved: {error.Message}", error: true);
            return false;
        }
    }

    public async void RecognizeText()
    {
        if (recognizing) return;
        recognizing = true;
        try
        {
            var image = await RenderedImageAsync();
            SetStatus("Recognizing text on this PC…");
            var lines = await StaWorker.Work.RunAsync(() => TextRecognizer.RecognizeAsync(image));
            infoWindow?.Close();
            infoWindow = Dialogs.TextWindow(this, string.Join("\n", lines.Select(line => line.Text)));
            SetStatus($"{lines.Count} text regions recognized");
        }
        catch (Exception error) { ShowError(error); }
        finally { recognizing = false; }
    }

    public void SetStatus(string text, bool error = false)
    {
        statusLabel.Text = text;
        statusLabel.ToolTip = text;
        statusLabel.SetResourceReference(TextBlock.ForegroundProperty, error ? "StudioError" : "StudioSecondaryText");
    }

    private void ShowError(Exception error)
    {
        SetStatus(error.Message, error: true);
        Dialogs.Error(this, error);
    }

    // MARK: Keyboard

    private void OnPreviewKeyDown(object sender, KeyEventArgs e)
    {
        if (Keyboard.FocusedElement is TextBoxBase or PasswordBox || (Keyboard.FocusedElement is ComboBox { IsEditable: true })) return;
        var key = e.Key == Key.System ? e.SystemKey : e.Key;
        var modifiers = Keyboard.Modifiers;
        if (modifiers == ModifierKeys.Control)
        {
            e.Handled = true;
            switch (key)
            {
                case Key.C: CopyImage(); return;
                case Key.S: SaveImage(); return;
                case Key.Z: UndoEdit(); return;
                case Key.Y: RedoEdit(); return;
                case Key.O: OpenRequested?.Invoke(); return;
                case Key.V: PasteRequested?.Invoke(); return;
                case Key.A: SetTool(EditorTool.Select); return;
                case Key.OemPlus or Key.Add: Canvas.ChangeZoom(1.2); return;
                case Key.OemMinus or Key.Subtract: Canvas.ChangeZoom(1 / 1.2); return;
                case Key.D0 or Key.NumPad0: Canvas.Fit(); return;
                case Key.D1 or Key.NumPad1: ShowInspectorSection(0); return;
                case Key.D2 or Key.NumPad2: ShowInspectorSection(1); return;
                case Key.D3 or Key.NumPad3: ShowInspectorSection(2); return;
                case Key.W: Close(); return;
            }
            e.Handled = false;
            return;
        }
        if (modifiers == (ModifierKeys.Control | ModifierKeys.Shift))
        {
            if (key == Key.Z) { RedoEdit(); e.Handled = true; }
            else if (key == Key.T) { ReopenRequested?.Invoke(); e.Handled = true; }
            return;
        }
        if (modifiers != ModifierKeys.None) return;
        // Focused buttons keep Space and Enter; sliders keep their arrow keys.
        switch (key)
        {
            case Key.Delete or Key.Back: Canvas.DeleteSelection(); e.Handled = true; return;
            case Key.Escape:
                Canvas.FinishText(cancel: true);
                if (Canvas.Tool == EditorTool.Select) { Canvas.CancelPointerGesture(); Canvas.ClearSelection(); Canvas.Focus(); }
                else SetTool(EditorTool.Select);
                e.Handled = true;
                return;
            case Key.C: CopyImage(); e.Handled = true; return;
            case Key.S: SaveImage(); e.Handled = true; return;
        }
        EditorTool? tool = key switch
        {
            Key.V => EditorTool.Select, Key.D => EditorTool.Pen, Key.A => EditorTool.Arrow, Key.R => EditorTool.Rectangle,
            Key.E => EditorTool.Ellipse, Key.T => EditorTool.Text, Key.H => EditorTool.Highlighter, Key.B => EditorTool.Blur,
            Key.K => EditorTool.Redact, Key.N => EditorTool.Number, Key.X => EditorTool.Crop, Key.L => EditorTool.Line,
            _ => null
        };
        if (tool is { } chosen) { SetTool(chosen); e.Handled = true; }
    }

    // MARK: Closing

    private void OnClosing()
    {
        Canvas.FinishText();
        Canvas.FinishPointerGesture();
        PersistHistory();
        userIsClosing = true;
        analysisWork.Cancel();
        backgroundWork.Cancel();
        infoWindow?.Close();
    }

    /// <summary>Linear undo of whole edit states, 100 levels.</summary>
    private sealed class EditHistory
    {
        private readonly List<(EditState Before, EditState After)> undo = new();
        private readonly List<(EditState Before, EditState After)> redo = new();
        public bool CanUndo => undo.Count > 0;
        public bool CanRedo => redo.Count > 0;

        public void Record(EditState before, EditState after)
        {
            undo.Add((before.Clone(), after.Clone()));
            if (undo.Count > 100) undo.RemoveAt(0);
            redo.Clear();
        }

        public EditState? Undo()
        {
            if (undo.Count == 0) return null;
            var step = undo[^1];
            undo.RemoveAt(undo.Count - 1);
            redo.Add(step);
            return step.Before;
        }

        public EditState? Redo()
        {
            if (redo.Count == 0) return null;
            var step = redo[^1];
            redo.RemoveAt(redo.Count - 1);
            undo.Add(step);
            return step.After;
        }
    }
}
