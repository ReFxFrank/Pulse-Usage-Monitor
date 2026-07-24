// Ported from CheesyPoofs346/openusage-windows (tray/) under the MIT License,
// Copyright (c) 2026 Robin Ebers. Renamed per that project's trademark policy;
// adapted to be fed by Pulse's local /api/summary. See strip/LICENSE-openusage.

using System.Drawing.Drawing2D;
using System.Drawing.Text;
using System.Globalization;
using System.Linq;
using System.Runtime.InteropServices;
using System.Text.Json;

namespace PulseStrip;

// The macOS "menu-bar pin" strip, recreated on the Windows taskbar. A borderless, per-pixel-alpha
// (layered) always-on-top window that draws the pinned provider metrics directly onto the taskbar —
// no system-tray icon. Left-click expands the popover; drag to reposition; right-click for the menu.
sealed class StripForm : Form
{
    public Action? OnClick;
    public Action? OnRefresh;
    public Action? OnQuit;
    public Action? OnOpenDashboard;
    public Func<bool>? IsDark;

    // Each provider carries BOTH its usage (% left, up to two lines) and its price (30-day API-cost).
    // The strip rotates between the two with a vertical roll animation.
    private sealed record Cell(string ProviderId, string UsageTop, string UsageBottom, string Price)
    {
        public bool HasUsage => UsageTop.Length > 0;
        public bool HasPrice => Price.Length > 0;
    }
    private List<Cell> _cells = new();

    // Rotation state: false = show usage, true = show price. `_flipping`/`_flipProgress` drive the roll.
    private bool _showPrice;
    private bool _flipping;
    private float _flipProgress;

    /// Whether the strip currently has any provider metrics to show (vs. the "Pulse" resting state).
    public bool HasCells => _cells.Count > 0;

    private int _anchorRight;   // the strip grows leftward from this x (kept near the tray)
    private int _y;
    private bool _posLoaded;
    private Point _dragMouseStart;
    private Point _dragWinStart;
    private bool _dragging;
    private bool _moved;

    private const int Height_ = 40;
    private static readonly string PosFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile),
        ".pulse", "strip.json");

    public StripForm()
    {
        FormBorderStyle = FormBorderStyle.None;
        ShowInTaskbar = false;
        StartPosition = FormStartPosition.Manual;
        TopMost = true;
        BackColor = Color.Black;
        // The visuals come entirely from UpdateLayeredWindow; stop WinForms from erasing to its default
        // (light) background, which was the "white box" flash before the alpha bitmap landed.
        SetStyle(ControlStyles.AllPaintingInWmPaint | ControlStyles.Opaque | ControlStyles.UserPaint, true);
        _cells = LoadCache(); // show last-known values instantly at launch
        LoadPosition();

        var reassert = new System.Windows.Forms.Timer { Interval = 2000 };
        reassert.Tick += (_, _) => KeepOnTop();
        reassert.Start();

        // Rotate usage <-> price on a relaxed cadence (2x slower than before); flip timer runs only
        // during the roll.
        _rotate = new System.Windows.Forms.Timer { Interval = 9000 };
        _rotate.Tick += (_, _) => StartFlip();
        _rotate.Start();
        _flipTimer = new System.Windows.Forms.Timer { Interval = 16 };
        _flipTimer.Tick += (_, _) => AdvanceFlip();
    }

    private readonly System.Windows.Forms.Timer _rotate;
    private readonly System.Windows.Forms.Timer _flipTimer;

    private void StartFlip()
    {
        // Only animate if at least one provider actually has both a usage and a price to swap between.
        if (_flipping || !_cells.Any(c => c.HasUsage && c.HasPrice)) return;
        _showPrice = !_showPrice;   // becomes the incoming view; the outgoing view is its opposite
        _flipping = true;
        _flipProgress = 0f;
        _flipTimer.Start();
    }

    private void AdvanceFlip()
    {
        _flipProgress += 0.05f; // ~20 frames ≈ 320ms (slower, smoother roll)
        if (_flipProgress >= 1f) { _flipProgress = 1f; _flipping = false; _flipTimer.Stop(); }
        if (IsHandleCreated) Render();
    }

    private static float Ease(float t) => t < 0.5f ? 2 * t * t : 1 - (float)Math.Pow(-2 * t + 2, 2) / 2;

    protected override CreateParams CreateParams
    {
        get
        {
            const int WS_EX_LAYERED = 0x80000, WS_EX_TOOLWINDOW = 0x80, WS_EX_TOPMOST = 0x8, WS_EX_NOACTIVATE = 0x8000000;
            var cp = base.CreateParams;
            cp.ExStyle |= WS_EX_LAYERED | WS_EX_TOOLWINDOW | WS_EX_TOPMOST | WS_EX_NOACTIVATE;
            return cp;
        }
    }

    protected override bool ShowWithoutActivation => true;

    // ---- data ----
    public void SetData(string uiJson)
    {
        var cells = new List<Cell>();
        try
        {
            using var doc = JsonDocument.Parse(string.IsNullOrWhiteSpace(uiJson) ? "[]" : uiJson);
            // Accept both the bare array and the {providers, errors} wrapper.
            JsonElement providers = doc.RootElement;
            if (doc.RootElement.ValueKind == JsonValueKind.Object && doc.RootElement.TryGetProperty("providers", out var pv))
                providers = pv;
            if (providers.ValueKind == JsonValueKind.Array)
            {
                foreach (var p in providers.EnumerateArray())
                {
                    string id = p.TryGetProperty("providerId", out var pid) ? pid.GetString() ?? "" : "";
                    var pcts = new List<int>();
                    double? spend30 = null;
                    if (p.TryGetProperty("lines", out var lines))
                        foreach (var l in lines.EnumerateArray())
                        {
                            string type = l.TryGetProperty("type", out var t) ? t.GetString() ?? "" : "";
                            if (type == "progress" && pcts.Count < 2
                                && l.TryGetProperty("format", out var fmt) && fmt.TryGetProperty("kind", out var kind) && kind.GetString() == "percent")
                            {
                                double used = l.TryGetProperty("used", out var u) && u.TryGetDouble(out var uv) ? uv : 0;
                                double limit = l.TryGetProperty("limit", out var li) && li.TryGetDouble(out var lv) && lv > 0 ? lv : 100;
                                pcts.Add((int)Math.Round(Math.Clamp(100 - used * 100 / limit, 0, 100)));
                            }
                            else if (type == "text" && l.TryGetProperty("label", out var lab) && lab.GetString() == "Last 30 Days"
                                && l.TryGetProperty("value", out var val))
                            {
                                spend30 = ParseDollars(val.GetString());
                            }
                        }
                    if (id.Length == 0) continue;
                    string uTop = pcts.Count > 0 ? pcts[0] + "%" : "";
                    string uBot = pcts.Count > 1 ? pcts[1] + "%" : "";
                    string price = spend30 is > 0 ? CompactMoney(spend30.Value) : "";
                    // Keep the provider if it has EITHER usage or price; the strip rotates between whatever
                    // it has (a provider with only one just shows that one, no flip).
                    if (uTop.Length > 0 || price.Length > 0)
                        cells.Add(new Cell(id, uTop, uBot, price));
                }
            }
        }
        catch { }
        // Stale-while-revalidate: a transient empty read must not blank the strip. Keep (and persist)
        // the last-known cells so even a restart shows real values immediately.
        if (cells.Count > 0)
        {
            _cells = cells;
            SaveCache();
            if (IsHandleCreated) Render();
        }
        else if (_cells.Count == 0)
        {
            _cells = LoadCache();
            if (IsHandleCreated) Render();
        }
    }

    // The server formats money invariantly ("$2,263.58"), so parse it invariantly too.
    // A culture-sensitive double.TryParse reads '.' as a GROUP separator on comma-decimal
    // locales (de-DE, pt-BR, …) and turns 2263.58 into 226358 — a 100x-wrong strip.
    private static double? ParseDollars(string? s)
    {
        if (string.IsNullOrEmpty(s)) return null;
        var m = System.Text.RegularExpressions.Regex.Match(s.Replace(",", ""), @"\$([0-9.]+)");
        return m.Success && double.TryParse(m.Groups[1].Value, NumberStyles.Float,
            CultureInfo.InvariantCulture, out var v) ? v : null;
    }

    private static string CompactMoney(double n)
        => n >= 1000
            ? "$" + (n / 1000).ToString(n / 1000 >= 100 ? "0" : "0.0", CultureInfo.InvariantCulture) + "K"
            : "$" + n.ToString("0", CultureInfo.InvariantCulture);

    private static readonly string CacheFile = Path.Combine(
        Environment.GetFolderPath(Environment.SpecialFolder.UserProfile), ".pulse", "strip_cells.json");

    private void SaveCache()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(CacheFile)!);
            File.WriteAllText(CacheFile, JsonSerializer.Serialize(_cells));
        }
        catch { }
    }

    private static List<Cell> LoadCache()
    {
        try { return JsonSerializer.Deserialize<List<Cell>>(File.ReadAllText(CacheFile)) ?? new(); }
        catch { return new(); }
    }

    protected override void OnHandleCreated(EventArgs e)
    {
        base.OnHandleCreated(e);
        Render();
    }

    protected override void OnShown(EventArgs e)
    {
        base.OnShown(e);
        Render(); // ensure the alpha bitmap is applied once the window is actually visible
    }

    // ULW supplies every pixel — never let WinForms paint (that was the white flash).
    protected override void OnPaintBackground(PaintEventArgs e) { }
    protected override void OnPaint(PaintEventArgs e) { }

    // ---- rendering (layered, per-pixel alpha) ----
    private void Render()
    {
        bool dark = IsDark?.Invoke() ?? true;
        // On the (typically dark) Win11 taskbar, white primary + gray secondary reads like the Mac strip.
        Color c1 = Color.FromArgb(240, 240, 240);
        Color c2 = Color.FromArgb(150, 150, 155);
        Color glyphC = Color.FromArgb(225, 225, 228);

        using var fTop = new Font("Segoe UI", 9f, FontStyle.Bold, GraphicsUnit.Point);
        using var fBot = new Font("Segoe UI", 8f, FontStyle.Regular, GraphicsUnit.Point);
        // Typographic layout trims GDI+'s built-in text padding so the numbers sit tight to the glyph.
        using var sf = new StringFormat(StringFormat.GenericTypographic) { FormatFlags = StringFormatFlags.NoWrap };

        string iconsRoot = WebAssets.IconsDir;

        // Measure each cell's value width (the max of its usage/price strings) so gaps are even and the
        // layout never jumps mid-flip.
        using var measureBmp = new Bitmap(1, 1);
        using var mg = Graphics.FromImage(measureBmp);
        // GDI+ bitmaps inherit the SCREEN dpi in a DPI-aware (PerMonitorV2) process, so the point-sized
        // fonts render scaled (1.5x at 150%) while pixel constants don't — on high-DPI displays the text
        // outgrew the glyph and sat below the centerline. Scale every layout constant and text offset by
        // the same factor the fonts get; at 96 dpi this is exactly the old layout.
        float k = mg.DpiY / 96f;
        int gGlyph = (int)MathF.Round(19 * k), gGap = (int)MathF.Round(8 * k),
            cellPad = (int)MathF.Round(18 * k), leftPad = (int)MathF.Round(12 * k);
        int h = (int)MathF.Round(Height_ * k);
        float ValW(Cell c)
        {
            float w = 0;
            if (c.HasUsage)
            {
                w = Math.Max(w, mg.MeasureString(c.UsageTop, fTop, 999, sf).Width);
                if (c.UsageBottom.Length > 0) w = Math.Max(w, mg.MeasureString(c.UsageBottom, fBot, 999, sf).Width);
            }
            if (c.HasPrice) w = Math.Max(w, mg.MeasureString(c.Price, fTop, 999, sf).Width);
            return w;
        }
        var widths = _cells.Select(ValW).ToList();

        int total = leftPad;
        for (int i = 0; i < _cells.Count; i++) total += gGlyph + gGap + (int)Math.Ceiling(widths[i]) + cellPad;
        if (_cells.Count == 0) total = 120;

        using var bmp = new Bitmap(Math.Max(total, 1), h);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias;
            g.TextRenderingHint = TextRenderingHint.AntiAlias;
            g.Clear(Color.Transparent);
            // Near-invisible full-rect backing (alpha 1) so the WHOLE strip is a click target — layered
            // windows treat alpha-0 pixels as click-through.
            using (var hit = new SolidBrush(Color.FromArgb(1, 0, 0, 0)))
                g.FillRectangle(hit, 0, 0, bmp.Width, bmp.Height);

            using var b1 = new SolidBrush(c1);
            using var b2 = new SolidBrush(c2);

            if (_cells.Count == 0)
            {
                using var fb = new Font("Segoe UI", 8.5f, FontStyle.Regular);
                g.DrawString("Pulse", fb, b2, leftPad, h / 2f - 8 * k, sf);
            }

            int x = leftPad;
            for (int i = 0; i < _cells.Count; i++)
            {
                var cell = _cells[i];
                var glyphRect = new RectangleF(x, (h - gGlyph) / 2f, gGlyph, gGlyph);
                var file = Path.Combine(iconsRoot, cell.ProviderId + ".svg");
                if (File.Exists(file)) { var p = SvgPath.FromFile(file, glyphRect, 0.04f); if (p != null) { using var gb = new SolidBrush(glyphC); g.FillPath(gb, p); p.Dispose(); } }
                x += gGlyph + gGap;

                float vw = widths[i];
                bool canFlip = cell.HasUsage && cell.HasPrice;
                if (_flipping && canFlip)
                {
                    // Vertical roll: outgoing view slides up and out, incoming rolls up from below.
                    g.SetClip(new RectangleF(x - 2 * k, 2 * k, vw + 8 * k, h - 4 * k));
                    float roll = 20f * k;
                    float e = Ease(_flipProgress);
                    DrawValue(g, x, cell, !_showPrice, h / 2f - e * roll, fTop, fBot, sf, b1, b2, k);
                    DrawValue(g, x, cell, _showPrice, h / 2f + (1 - e) * roll, fTop, fBot, sf, b1, b2, k);
                    g.ResetClip();
                }
                else
                {
                    bool priceView = cell.HasPrice && (_showPrice || !cell.HasUsage);
                    DrawValue(g, x, cell, priceView, h / 2f, fTop, fBot, sf, b1, b2, k);
                }
                x += (int)Math.Ceiling(vw) + cellPad;
            }
        }

        Size = new Size(bmp.Width, bmp.Height);
        int left = _anchorRight - bmp.Width;
        base.SetBounds(left, _y, bmp.Width, bmp.Height, BoundsSpecified.Location | BoundsSpecified.Size);
        SetBitmap(bmp);
        KeepOnTop();
    }

    // Draw one cell's value block (usage = two lines, price = one bold line), centered on `centerY`.
    // `k` = dpi scale (see Render): the pixel offsets that center the text must grow with the fonts.
    private static void DrawValue(Graphics g, float x, Cell cell, bool isPrice, float centerY,
        Font fTop, Font fBot, StringFormat sf, Brush b1, Brush b2, float k = 1f)
    {
        if (isPrice)
        {
            g.DrawString(cell.Price, fTop, b1, x, centerY - 7 * k, sf);
        }
        else if (cell.UsageBottom.Length > 0)
        {
            g.DrawString(cell.UsageTop, fTop, b1, x, centerY - 15 * k, sf);
            g.DrawString(cell.UsageBottom, fBot, b2, x, centerY + 1 * k, sf);
        }
        else
        {
            g.DrawString(cell.UsageTop, fTop, b1, x, centerY - 8 * k, sf);
        }
    }

    // ---- positioning ----
    private void LoadPosition()
    {
        var scr = Screen.PrimaryScreen!;
        int taskbarH = scr.Bounds.Height - scr.WorkingArea.Height;
        if (taskbarH <= 0) taskbarH = 48;
        _anchorRight = scr.Bounds.Right - 175;                       // sit closer to the clock (nicer default)
        int hs = (int)MathF.Round(Height_ * (DeviceDpi / 96f));      // rendered height is dpi-scaled (see Render)
        _y = scr.Bounds.Bottom - taskbarH + (taskbarH - hs) / 2;
        try
        {
            if (File.Exists(PosFile))
            {
                using var doc = JsonDocument.Parse(File.ReadAllText(PosFile));
                var r = doc.RootElement;
                if (r.TryGetProperty("right", out var pr)) _anchorRight = pr.GetInt32();
                if (r.TryGetProperty("y", out var py)) _y = py.GetInt32();
            }
        }
        catch { }
        // keep on-screen
        _anchorRight = Math.Clamp(_anchorRight, scr.Bounds.Left + 80, scr.Bounds.Right);
        _y = Math.Clamp(_y, scr.Bounds.Top, scr.Bounds.Bottom - hs);
        _posLoaded = true;
    }

    private void SavePosition()
    {
        try
        {
            Directory.CreateDirectory(Path.GetDirectoryName(PosFile)!);
            File.WriteAllText(PosFile, $"{{\"right\":{_anchorRight},\"y\":{_y}}}");
        }
        catch { }
    }

    public void ResetPosition()
    {
        try { if (File.Exists(PosFile)) File.Delete(PosFile); } catch { }
        _posLoaded = false; LoadPosition(); Render();
    }

    private void KeepOnTop()
    {
        if (!IsHandleCreated) return;
        // HWND_TOPMOST, no activate/move/size — just re-assert z-order above the taskbar.
        SetWindowPos(Handle, new IntPtr(-1), 0, 0, 0, 0, 0x0001 | 0x0002 | 0x0010);
    }

    // ---- mouse: click to expand, drag to move, right-click menu ----
    protected override void OnMouseDown(MouseEventArgs e)
    {
        if (e.Button == MouseButtons.Left)
        {
            _dragging = true; _moved = false;
            _dragMouseStart = Cursor.Position;
            _dragWinStart = new Point(Left, Top);
        }
        else if (e.Button == MouseButtons.Right)
        {
            ShowMenu();
        }
    }

    protected override void OnMouseMove(MouseEventArgs e)
    {
        if (!_dragging) return;
        var d = new Point(Cursor.Position.X - _dragMouseStart.X, Cursor.Position.Y - _dragMouseStart.Y);
        if (Math.Abs(d.X) + Math.Abs(d.Y) > 3) _moved = true;
        if (_moved)
        {
            int nx = _dragWinStart.X + d.X, ny = _dragWinStart.Y + d.Y;
            _anchorRight = nx + Width; _y = ny;
            base.SetBounds(nx, ny, Width, Height, BoundsSpecified.Location);
        }
    }

    protected override void OnMouseUp(MouseEventArgs e)
    {
        if (e.Button != MouseButtons.Left) return;
        _dragging = false;
        if (_moved) SavePosition();
        else OnClick?.Invoke();
    }

    private void ShowMenu()
    {
        var m = new ContextMenuStrip();
        m.Items.Add("Open dashboard", null, (_, _) => OnOpenDashboard?.Invoke());
        m.Items.Add("Quick view", null, (_, _) => OnClick?.Invoke());
        m.Items.Add("Refresh", null, (_, _) => OnRefresh?.Invoke());
        m.Items.Add("Reset strip position", null, (_, _) => ResetPosition());
        m.Items.Add(new ToolStripSeparator());
        m.Items.Add("Quit strip", null, (_, _) => OnQuit?.Invoke());
        m.Show(Cursor.Position);
    }

    // ---- layered-window plumbing (UpdateLayeredWindow) ----
    private void SetBitmap(Bitmap bmp)
    {
        if (!IsHandleCreated) return;
        IntPtr screenDc = GetDC(IntPtr.Zero);
        IntPtr memDc = CreateCompatibleDC(screenDc);
        IntPtr hBmp = bmp.GetHbitmap(Color.FromArgb(0));
        IntPtr old = SelectObject(memDc, hBmp);
        var size = new SIZE { cx = bmp.Width, cy = bmp.Height };
        var src = new POINT { x = 0, y = 0 };
        var top = new POINT { x = Left, y = Top };
        var blend = new BLENDFUNCTION { BlendOp = 0, BlendFlags = 0, SourceConstantAlpha = 255, AlphaFormat = 1 };
        UpdateLayeredWindow(Handle, screenDc, ref top, ref size, memDc, ref src, 0, ref blend, 2);
        SelectObject(memDc, old); DeleteObject(hBmp); DeleteDC(memDc); ReleaseDC(IntPtr.Zero, screenDc);
    }

    [StructLayout(LayoutKind.Sequential)] private struct POINT { public int x, y; }
    [StructLayout(LayoutKind.Sequential)] private struct SIZE { public int cx, cy; }
    [StructLayout(LayoutKind.Sequential)] private struct BLENDFUNCTION { public byte BlendOp, BlendFlags, SourceConstantAlpha, AlphaFormat; }

    [DllImport("user32.dll")] private static extern IntPtr GetDC(IntPtr h);
    [DllImport("user32.dll")] private static extern int ReleaseDC(IntPtr h, IntPtr dc);
    [DllImport("user32.dll", SetLastError = true)] private static extern bool UpdateLayeredWindow(IntPtr h, IntPtr dst, ref POINT ppd, ref SIZE ps, IntPtr src, ref POINT pps, int cr, ref BLENDFUNCTION bf, int flags);
    [DllImport("user32.dll")] private static extern bool SetWindowPos(IntPtr h, IntPtr after, int x, int y, int cx, int cy, uint flags);
    [DllImport("gdi32.dll")] private static extern IntPtr CreateCompatibleDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern IntPtr SelectObject(IntPtr dc, IntPtr obj);
    [DllImport("gdi32.dll")] private static extern bool DeleteDC(IntPtr dc);
    [DllImport("gdi32.dll")] private static extern bool DeleteObject(IntPtr obj);

    // headless render for verification
    public void RenderToFile(string png, bool showPrice)
    {
        using var fTop = new Font("Segoe UI", 9f, FontStyle.Bold);
        using var fBot = new Font("Segoe UI", 8f);
        using var sf = new StringFormat(StringFormat.GenericTypographic) { FormatFlags = StringFormatFlags.NoWrap };
        using var mb = new Bitmap(1, 1); using var mg = Graphics.FromImage(mb);
        float ValW(Cell c)
        {
            float w = 0;
            if (c.HasUsage) { w = Math.Max(w, mg.MeasureString(c.UsageTop, fTop, 999, sf).Width); if (c.UsageBottom.Length > 0) w = Math.Max(w, mg.MeasureString(c.UsageBottom, fBot, 999, sf).Width); }
            if (c.HasPrice) w = Math.Max(w, mg.MeasureString(c.Price, fTop, 999, sf).Width);
            return w;
        }
        const int gGlyph = 19, gGap = 8, cellPad = 18, leftPad = 12; int h = Height_;
        var widths = _cells.Select(ValW).ToList();
        int total = leftPad; for (int i = 0; i < _cells.Count; i++) total += gGlyph + gGap + (int)Math.Ceiling(widths[i]) + cellPad;
        using var bmp = new Bitmap(Math.Max(total, 120), h);
        using (var g = Graphics.FromImage(bmp))
        {
            g.SmoothingMode = SmoothingMode.AntiAlias; g.TextRenderingHint = TextRenderingHint.AntiAlias;
            g.Clear(Color.FromArgb(28, 28, 30)); // simulate the dark taskbar
            using var b1 = new SolidBrush(Color.FromArgb(240, 240, 240));
            using var b2 = new SolidBrush(Color.FromArgb(150, 150, 155));
            using var gb = new SolidBrush(Color.FromArgb(225, 225, 228));
            string iconsRoot = WebAssets.IconsDir;
            int x = leftPad;
            for (int i = 0; i < _cells.Count; i++)
            {
                var cell = _cells[i];
                var rect = new RectangleF(x, (h - gGlyph) / 2f, gGlyph, gGlyph);
                var file = Path.Combine(iconsRoot, cell.ProviderId + ".svg");
                if (File.Exists(file)) { var p = SvgPath.FromFile(file, rect, 0.04f); if (p != null) { g.FillPath(gb, p); p.Dispose(); } }
                x += gGlyph + gGap;
                bool priceView = cell.HasPrice && (showPrice || !cell.HasUsage);
                DrawValue(g, x, cell, priceView, h / 2f, fTop, fBot, sf, b1, b2);
                x += (int)Math.Ceiling(widths[i]) + cellPad;
            }
        }
        bmp.Save(png);
    }
}
