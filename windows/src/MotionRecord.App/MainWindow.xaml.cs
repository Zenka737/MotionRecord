using System.Diagnostics;
using System.Windows;
using System.Windows.Input;
using System.Windows.Interop;
using System.Windows.Threading;
using Microsoft.Win32;

namespace MotionRecord.App;

public partial class MainWindow : Window
{
    const int HotkeyId = 0x4D52;
    static readonly string LibraryRoot = Path.Combine(Environment.GetFolderPath(Environment.SpecialFolder.MyVideos), "MotionRecord");

    ScreenRecorder? _rec;
    EditorModel? _model;
    PreviewService? _preview;
    double _playhead;
    bool _playing, _loading, _busy;
    readonly DispatcherTimer _timer = new() { Interval = TimeSpan.FromMilliseconds(33) };
    Stopwatch _playClock = new();
    double _playFrom;
    CancellationTokenSource? _exportCts;

    static readonly (string label, AspectPreset v)[] Aspects =
    {
        ("16:9", AspectPreset.landscape16x9), ("Как в записи", AspectPreset.original), ("9:16 (вертикальное)", AspectPreset.vertical9x16),
        ("1:1", AspectPreset.square1x1), ("4:5", AspectPreset.portrait4x5), ("4:3", AspectPreset.standard4x3),
    };
    static readonly double[] Speeds = { 0.25, 0.5, 1, 1.5, 2, 4, 8 };

    public MainWindow()
    {
        InitializeComponent();
        foreach (var a in Aspects) CmbAspect.Items.Add(a.label);
        foreach (var s in Speeds) CmbSpeed.Items.Add($"{s:0.##}×");
        Timeline.Seek += t => SetPlayhead(t, true);
        _timer.Tick += OnTick;
        Loaded += (_, _) => { RefreshLibrary(); CheckFfmpeg(); };
        Closing += (_, _) => { _exportCts?.Cancel(); _preview?.Dispose(); };
        PreviewKeyDown += OnKey;
    }

    // ---- hotkey ---------------------------------------------------------------------------------------------------
    protected override void OnSourceInitialized(EventArgs e)
    {
        base.OnSourceInitialized(e);
        var src = (HwndSource)PresentationSource.FromVisual(this)!;
        src.AddHook((IntPtr h, int msg, IntPtr w, IntPtr l, ref bool handled) =>
        {
            if (msg == Native.WM_HOTKEY && w.ToInt32() == HotkeyId) { handled = true; OnRecordClick(null, null!); }
            return IntPtr.Zero;
        });
        if (!Native.RegisterHotKey(src.Handle, HotkeyId, Native.MOD_CONTROL | Native.MOD_SHIFT | Native.MOD_NOREPEAT, 0x52))
            TxtStatus.Text = "Горячая клавиша Ctrl+Shift+R занята — используйте кнопку.";
    }

    protected override void OnClosed(EventArgs e)
    {
        if (PresentationSource.FromVisual(this) is HwndSource s) Native.UnregisterHotKey(s.Handle, HotkeyId);
        base.OnClosed(e);
    }

    void CheckFfmpeg()
    {
        if (Ffmpeg.Locate() == null)
            TxtStatus.Text = "Не найден ffmpeg.exe — положите его рядом с MotionRecord.exe (см. README).";
    }

    // ---- recording ------------------------------------------------------------------------------------------------
    async void OnRecordClick(object? s, RoutedEventArgs e)
    {
        if (_busy) return;
        if (_rec == null)
        {
            var ff = Ffmpeg.Locate();
            if (ff == null) { MessageBox.Show("Нужен ffmpeg.exe рядом с приложением (см. README)."); return; }
            _busy = true;
            StopPlayback();
            for (var i = 3; i > 0; i--) { BtnRecord.Content = $"Старт через {i}…"; await Task.Delay(1000); }
            Directory.CreateDirectory(LibraryRoot);
            var fps = int.Parse(((System.Windows.Controls.ComboBoxItem)CmbFps.SelectedItem).Content.ToString()!);
            _rec = new ScreenRecorder(LibraryRoot, fps, ff);
            WindowState = WindowState.Minimized;
            await Task.Delay(400);                      // let the minimize animation finish before the first frame
            _rec.Start();
            BtnRecord.Content = "■ Стоп (Ctrl+Shift+R)";
            TxtStatus.Text = "Идёт запись… курсор и клики пишутся отдельно от картинки.";
            _busy = false;
        }
        else
        {
            _busy = true;
            var rec = _rec; _rec = null;
            string dir;
            try { dir = await Task.Run(() => rec.Stop()); }
            catch (Exception ex) { WindowState = WindowState.Normal; BtnRecord.Content = "● Запись"; _busy = false; MessageBox.Show(ex.Message); return; }
            WindowState = WindowState.Normal; Activate();
            BtnRecord.Content = "● Запись";
            TxtStatus.Text = "Запись сохранена: " + dir;
            _busy = false;
            RefreshLibrary(Path.GetFileName(dir));
        }
    }

    // ---- library --------------------------------------------------------------------------------------------------
    void RefreshLibrary(string? select = null)
    {
        _loading = true;
        LibList.Items.Clear();
        if (Directory.Exists(LibraryRoot))
            foreach (var d in Directory.GetDirectories(LibraryRoot).OrderByDescending(x => x))
                if (File.Exists(Path.Combine(d, "meta.json"))) LibList.Items.Add(Path.GetFileName(d));
        _loading = false;
        if (select != null) LibList.SelectedItem = select;
    }

    void OnRefreshLibrary(object s, RoutedEventArgs e) => RefreshLibrary();
    void OnOpenLibraryFolder(object s, RoutedEventArgs e) { Directory.CreateDirectory(LibraryRoot); Process.Start("explorer.exe", LibraryRoot); }
    void OnLibrarySelected(object s, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_loading || LibList.SelectedItem is not string name) return;
        OpenRecording(Path.Combine(LibraryRoot, name));
    }

    void OpenRecording(string dir)
    {
        StopPlayback();
        _preview?.Dispose();
        try { _model = new EditorModel(dir); }
        catch (Exception ex) { MessageBox.Show("Не удалось открыть запись: " + ex.Message); return; }
        _model.Changed += OnModelChanged;
        Timeline.Model = _model;
        TxtEmpty.Visibility = Visibility.Collapsed;
        _preview = new PreviewService(_model, bmp => PreviewImage.Source = bmp);
        if (!_preview.HasFfmpeg) TxtStatus.Text = "Предпросмотр без видео: нет ffmpeg.exe.";
        LoadInspector();
        SetPlayhead(0, true);
    }

    // ---- inspector <-> model --------------------------------------------------------------------------------------
    void LoadInspector()
    {
        if (_model == null) return;
        _loading = true;
        var p = _model.Project; var r = p.Render;
        ChkAutoZoom.IsChecked = r.AutoZoom; SldZoom.Value = r.ZoomScale;
        ChkShowCursor.IsChecked = p.Style.ShowCursor; ChkRipple.IsChecked = r.ShowClickRipple;
        SldSmooth.Value = r.CursorSmoothing; SldCursorSize.Value = r.CursorScale;
        SldPadding.Value = r.Padding; SldCorner.Value = r.CornerRadius;
        CmbAspect.SelectedIndex = Array.FindIndex(Aspects, a => a.v == p.Style.Aspect);
        _loading = false;
        UpdateSpeedBox();
    }

    void UpdateSpeedBox()
    {
        if (_model == null) return;
        _loading = true;
        var seg = _model.SelKind == SelKind.Segment
            ? _model.Project.EffectiveSegments(_model.Meta.Duration).FirstOrDefault(s => s.Id == _model.SelId) : null;
        CmbSpeed.IsEnabled = seg != null;
        CmbSpeed.SelectedIndex = seg == null ? -1 : Array.FindIndex(Speeds, s => Math.Abs(s - seg.Speed) < 1e-6);
        _loading = false;
    }

    void OnSliderChanged(object s, RoutedPropertyChangedEventArgs<double> e) => ApplySettings();
    void OnSettingChanged(object s, RoutedEventArgs e) => ApplySettings();

    void ApplySettings()
    {
        if (_loading || _model == null) return;
        _model.Live(p =>
        {
            p.Render.AutoZoom = ChkAutoZoom.IsChecked == true; p.Render.ZoomScale = SldZoom.Value;
            p.Style.ShowCursor = ChkShowCursor.IsChecked == true; p.Render.ShowClickRipple = ChkRipple.IsChecked == true;
            p.Render.CursorSmoothing = SldSmooth.Value; p.Render.CursorScale = SldCursorSize.Value;
            p.Render.Padding = SldPadding.Value; p.Render.CornerRadius = SldCorner.Value;
        });
    }

    void OnAspectChanged(object s, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_loading || _model == null || CmbAspect.SelectedIndex < 0) return;
        var v = Aspects[CmbAspect.SelectedIndex].v;
        _model.Commit(p => p.Style.Aspect = v);
    }

    void OnSpeedChanged(object s, System.Windows.Controls.SelectionChangedEventArgs e)
    {
        if (_loading || _model == null || CmbSpeed.SelectedIndex < 0) return;
        _model.SetSpeed(Speeds[CmbSpeed.SelectedIndex]);
    }

    void OnModelChanged()
    {
        if (_model == null) return;
        _playhead = Math.Min(_playhead, _model.OutputDuration);
        UpdateSpeedBox();
        Timeline.Playhead = _playhead;
        Timeline.InvalidateVisual();
        UpdateTime();
        _preview?.Request(_playhead);
    }

    // ---- playback -------------------------------------------------------------------------------------------------
    void SetPlayhead(double t, bool request)
    {
        if (_model == null) return;
        _playhead = Math.Clamp(t, 0, _model.OutputDuration);
        Timeline.Playhead = _playhead; Timeline.InvalidateVisual();
        UpdateTime();
        if (request) _preview?.Request(_playhead);
        if (_playing) { _playClock.Restart(); _playFrom = _playhead; }
    }

    void UpdateTime()
    {
        if (_model == null) return;
        static string F(double s) => $"{(int)s / 60}:{s % 60:00.0}";
        TxtTime.Text = $"{F(_playhead)} / {F(_model.OutputDuration)}";
    }

    void OnPlayClick(object s, RoutedEventArgs e) { if (_playing) StopPlayback(); else StartPlayback(); }

    void StartPlayback()
    {
        if (_model == null) return;
        if (_playhead >= _model.OutputDuration - 0.05) _playhead = 0;
        _playing = true; _playFrom = _playhead; _playClock.Restart(); _timer.Start();
        BtnPlay.Content = "❚❚ Пауза";
    }

    void StopPlayback() { _playing = false; _timer.Stop(); BtnPlay.Content = "▶ Играть"; }

    void OnTick(object? s, EventArgs e)
    {
        if (_model == null) { StopPlayback(); return; }
        var t = _playFrom + _playClock.Elapsed.TotalSeconds;
        if (t >= _model.OutputDuration) { SetPlayhead(_model.OutputDuration, true); StopPlayback(); return; }
        _playhead = t; Timeline.Playhead = t; Timeline.InvalidateVisual(); UpdateTime();
        _preview?.Request(t);
    }

    // ---- editing actions ------------------------------------------------------------------------------------------
    void OnSplit(object? s, RoutedEventArgs? e) => _model?.SplitAt(_playhead);
    void OnAddZoom(object? s, RoutedEventArgs? e) => _model?.AddZoom(_playhead);
    void OnDelete(object? s, RoutedEventArgs? e) => _model?.DeleteSelected();
    void OnUndo(object? s, RoutedEventArgs? e) => _model?.Undo();

    void OnAddText(object? s, RoutedEventArgs? e)
    {
        if (_model == null) return;
        var text = Prompt("Текст на видео:", "Привет!");
        if (!string.IsNullOrWhiteSpace(text)) _model.AddText(_playhead, text);
    }

    string? Prompt(string label, string initial)
    {
        var tb = new System.Windows.Controls.TextBox { Text = initial, Margin = new Thickness(0, 8, 0, 12), MinWidth = 280 };
        var ok = new System.Windows.Controls.Button { Content = "OK", IsDefault = true, Padding = new Thickness(16, 4, 16, 4), HorizontalAlignment = HorizontalAlignment.Right };
        var panel = new System.Windows.Controls.StackPanel { Margin = new Thickness(14) };
        panel.Children.Add(new System.Windows.Controls.TextBlock { Text = label, Foreground = System.Windows.Media.Brushes.Black });
        panel.Children.Add(tb); panel.Children.Add(ok);
        var w = new Window { Title = "MotionRecord", Content = panel, SizeToContent = SizeToContent.WidthAndHeight, Owner = this,
            WindowStartupLocation = WindowStartupLocation.CenterOwner, ResizeMode = ResizeMode.NoResize };
        ok.Click += (_, _) => w.DialogResult = true;
        tb.Loaded += (_, _) => { tb.Focus(); tb.SelectAll(); };
        return w.ShowDialog() == true ? tb.Text : null;
    }

    void OnKey(object s, KeyEventArgs e)
    {
        if (e.OriginalSource is System.Windows.Controls.TextBox) return;
        switch (e.Key)
        {
            case Key.Space: OnPlayClick(this, null!); e.Handled = true; break;
            case Key.S when Keyboard.Modifiers == ModifierKeys.None: OnSplit(null, null); e.Handled = true; break;
            case Key.Z when Keyboard.Modifiers == ModifierKeys.None: OnAddZoom(null, null); e.Handled = true; break;
            case Key.Z when Keyboard.Modifiers == ModifierKeys.Control: OnUndo(null, null); e.Handled = true; break;
            case Key.T when Keyboard.Modifiers == ModifierKeys.None: OnAddText(null, null); e.Handled = true; break;
            case Key.Delete: case Key.Back: OnDelete(null, null); e.Handled = true; break;
        }
    }

    // ---- export ---------------------------------------------------------------------------------------------------
    async void OnExportClick(object s, RoutedEventArgs e)
    {
        if (_model == null) return;
        if (_exportCts != null) { _exportCts.Cancel(); return; }
        var dlg = new SaveFileDialog { Filter = "MP4 (*.mp4)|*.mp4", FileName = "MotionRecord-" + Path.GetFileName(_model.Dir) + ".mp4",
            InitialDirectory = Environment.GetFolderPath(Environment.SpecialFolder.MyVideos) };
        if (dlg.ShowDialog(this) != true) return;
        StopPlayback();
        var model = _model;
        var meta = model.Meta;
        var proj = Json.Deserialize<EditProject>(Json.Serialize(model.Project))!;   // snapshot: edits during export don't leak in
        if (proj.ExportFormat == ExportFormat.gif || proj.ExportFormat == ExportFormat.mov) proj.ExportFormat = ExportFormat.mp4H264;
        _exportCts = new CancellationTokenSource();
        var ct = _exportCts.Token;
        BtnExport.Content = "Отменить экспорт"; ExportBar.Visibility = Visibility.Visible; ExportBar.Value = 0; TxtExport.Text = "";
        var prog = new Progress<double>(v => { ExportBar.Value = v; TxtExport.Text = $"{v:P0}"; });
        try
        {
            await Task.Run(() => Exporter.Export(model.Dir, meta, proj, dlg.FileName, prog, ct));
            TxtExport.Text = "Готово: " + dlg.FileName;
            Process.Start("explorer.exe", $"/select,\"{dlg.FileName}\"");
        }
        catch (OperationCanceledException) { TxtExport.Text = "Экспорт отменён."; try { File.Delete(dlg.FileName); } catch { } }
        catch (Exception ex) { TxtExport.Text = "Ошибка экспорта: " + ex.Message; }
        finally { _exportCts = null; BtnExport.Content = "Экспорт в MP4…"; ExportBar.Visibility = Visibility.Collapsed; }
    }
}
