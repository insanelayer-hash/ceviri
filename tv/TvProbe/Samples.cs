using System;
using System.Collections.Generic;

namespace TvProbe
{
    // Shape of a subtitle line: stroke counts in 2x4 px cells on a fixed screen grid, over
    // the line's own rectangle. Two captures of the same text give nearly the same cells
    // even when the background moves; different text does not, so this tells "still the
    // same line" from "a new line" without reading anything. (A subtitle line does not move
    // while it is up, and the same sentence shows at the same place next time.)
    sealed class LineSig
    {
        public const int CellW = 2, CellH = 4;
        public int Cx, Cy, Cw, Ch, Total;   // cell rectangle on the screen grid
        public byte[] Cells;

        // stroke/keepRow are band-relative; (offX, offY) is the band's origin on screen.
        public static LineSig Build(bool[] stroke, int stride, bool[] keepRow, int x0, int y0, int w, int h, int offX, int offY)
        {
            int ax = offX + x0, ay = offY + y0;
            var s = new LineSig { Cx = ax / CellW, Cy = ay / CellH };
            s.Cw = (ax + w - 1) / CellW - s.Cx + 1;
            s.Ch = (ay + h - 1) / CellH - s.Cy + 1;
            s.Cells = new byte[s.Cw * s.Ch];
            for (int yy = 0; yy < h; yy++)
            {
                if (!keepRow[y0 + yy]) continue;
                int row = (y0 + yy) * stride + x0, cellRow = ((ay + yy) / CellH - s.Cy) * s.Cw;
                for (int xx = 0; xx < w; xx++)
                    if (stroke[row + xx]) { s.Cells[cellRow + (ax + xx) / CellW - s.Cx]++; s.Total++; }
            }
            return s;
        }

        // 0 = identical, about 1 or more = unrelated.
        public static double Distance(LineSig a, LineSig b)
        {
            if (a == null || b == null) return 1;
            int max = Math.Max(a.Total, b.Total);
            if (max == 0) return 1;
            int xa = Math.Min(a.Cx, b.Cx), xb = Math.Max(a.Cx + a.Cw, b.Cx + b.Cw);
            int ya = Math.Min(a.Cy, b.Cy), yb = Math.Max(a.Cy + a.Ch, b.Cy + b.Ch);
            int d = 0;
            for (int y = ya; y < yb; y++)
            {
                int ra = y - a.Cy, rb = y - b.Cy;
                bool inA = ra >= 0 && ra < a.Ch, inB = rb >= 0 && rb < b.Ch;
                for (int x = xa; x < xb; x++)
                {
                    int ca = x - a.Cx, cb = x - b.Cx;
                    int va = inA && ca >= 0 && ca < a.Cw ? a.Cells[ra * a.Cw + ca] : 0;
                    int vb = inB && cb >= 0 && cb < b.Cw ? b.Cells[rb * b.Cw + cb] : 0;
                    d += va > vb ? va - vb : vb - va;
                }
                if (d > max * 2) break;
            }
            return d / (double)max;
        }
    }

    // Lines already translated in this session, by shape: a repeated line is shown at once,
    // without asking the phone.
    static class LineCache
    {
        class Entry { public LineSig Sig; public string Tr; }
        static readonly List<Entry> _entries = new List<Entry>();

        public static string Lookup(LineSig sig)
        {
            string best = null; double bestD = 0.22;
            lock (_entries)
            {
                foreach (var e in _entries)
                {
                    if (Math.Abs(e.Sig.Cw - sig.Cw) > 3 || Math.Abs(e.Sig.Ch - sig.Ch) > 1) continue;
                    double d = LineSig.Distance(e.Sig, sig);
                    if (d < bestD) { bestD = d; best = e.Tr; }
                }
            }
            return best;
        }

        public static void Add(LineSig sig, string tr)
        {
            if (sig == null || string.IsNullOrEmpty(tr)) return;
            lock (_entries)
            {
                _entries.Add(new Entry { Sig = sig, Tr = tr });
                if (_entries.Count > 1500) _entries.RemoveAt(0);
            }
        }

        public static int Count { get { lock (_entries) return _entries.Count; } }
    }
}
