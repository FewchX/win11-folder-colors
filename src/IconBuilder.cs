// Builds the colored folder icons on the user's own machine, from the stock
// Windows folder icon (imageres.dll, icon group 3). The repository ships no
// Microsoft artwork: every install recolors the icon of the Windows it runs on.
//
// Each frame of the stock icon is recolored with a gradient map: the pixel's
// HSL lightness picks a spot on a dark -> mid -> light ramp of the target
// color, alpha is kept as is. That keeps the native shading (darker back tab,
// lighter front panel, edge line) at every size.
//
//   FolderColor.exe build-icons <iconsDir> <assetsDir> <id>=<dark>,<mid>,<light>...
//
// Writes <iconsDir>\<id>.ico per color, <iconsDir>\menu.ico (the stock folder
// in vertical bands of all the colors) and the logos the package manifest
// requires into <assetsDir>.

using System;
using System.Collections.Generic;
using System.Drawing;
using System.Drawing.Drawing2D;
using System.Drawing.Imaging;
using System.IO;
using System.Runtime.InteropServices;

static class IconBuilder
{
    const int FolderGroup = 3;
    const int RT_ICON = 3, RT_GROUP_ICON = 14;
    const uint LOAD_LIBRARY_AS_DATAFILE = 0x2, LOAD_LIBRARY_AS_IMAGE_RESOURCE = 0x20;

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
    static extern IntPtr LoadLibraryExW(string path, IntPtr file, uint flags);
    [DllImport("kernel32.dll")] static extern bool FreeLibrary(IntPtr module);
    [DllImport("kernel32.dll")] static extern IntPtr FindResourceW(IntPtr module, IntPtr name, IntPtr type);
    [DllImport("kernel32.dll")] static extern IntPtr LoadResource(IntPtr module, IntPtr res);
    [DllImport("kernel32.dll")] static extern IntPtr LockResource(IntPtr data);
    [DllImport("kernel32.dll")] static extern uint SizeofResource(IntPtr module, IntPtr res);

    /// <summary>Straight-alpha BGRA pixels, top-down.</summary>
    sealed class Frame
    {
        public int Size;
        public byte[] Bgra;
        public Frame(int size) { Size = size; Bgra = new byte[size * size * 4]; }
    }

    sealed class Ramp
    {
        public double[] Dark, Mid, Light;
    }

    public static int Run(string[] args)
    {
        if (args.Length < 4) throw new ArgumentException("Usage: build-icons <iconsDir> <assetsDir> <id>=<dark>,<mid>,<light>...");
        string iconsDir = args[1], assetsDir = args[2];
        var ids = new List<string>();
        var ramps = new List<Ramp>();
        for (int i = 3; i < args.Length; i++)
        {
            int eq = args[i].IndexOf('=');
            string[] hex = eq > 0 ? args[i].Substring(eq + 1).Split(',') : new string[0];
            if (hex.Length != 3) throw new ArgumentException("Bad color spec: " + args[i]);
            ids.Add(args[i].Substring(0, eq));
            ramps.Add(new Ramp { Dark = Rgb(hex[0]), Mid = Rgb(hex[1]), Light = Rgb(hex[2]) });
        }

        List<Frame> stock = LoadStockIcon();
        var ranges = new Dictionary<Frame, double[]>();
        foreach (Frame f in stock) ranges[f] = LightnessRange(f);

        Directory.CreateDirectory(iconsDir);
        for (int c = 0; c < ids.Count; c++)
        {
            var frames = new List<Frame>();
            Ramp ramp = ramps[c];
            foreach (Frame f in stock) frames.Add(Recolor(f, ranges[f], (x, y) => ramp));
            WriteIco(frames, Path.Combine(iconsDir, ids[c] + ".ico"));
        }

        // menu icon: one vertical band per color
        var menu = new List<Frame>();
        foreach (Frame f in stock)
        {
            int size = f.Size;
            menu.Add(Recolor(f, ranges[f], (x, y) => ramps[Math.Min(ramps.Count - 1, x * ramps.Count / size)]));
        }
        WriteIco(menu, Path.Combine(iconsDir, "menu.ico"));

        // logos the package manifest requires (the package has no visible app)
        Directory.CreateDirectory(assetsDir);
        Frame big = menu[0];
        foreach (Frame f in menu) if (f.Size > big.Size) big = f;
        using (Bitmap src = ToBitmap(big))
        {
            SaveScaled(src, 50, Path.Combine(assetsDir, "StoreLogo.png"));
            SaveScaled(src, 44, Path.Combine(assetsDir, "Square44x44Logo.png"));
            SaveScaled(src, 150, Path.Combine(assetsDir, "Square150x150Logo.png"));
        }
        return 0;
    }

    // --- stock icon -----------------------------------------------------------

    static List<Frame> LoadStockIcon()
    {
        string windir = Environment.GetEnvironmentVariable("WINDIR");
        string mun = Path.Combine(windir, @"SystemResources\imageres.dll.mun");
        string path = File.Exists(mun) ? mun : Path.Combine(windir, @"System32\imageres.dll");
        IntPtr module = LoadLibraryExW(path, IntPtr.Zero, LOAD_LIBRARY_AS_DATAFILE | LOAD_LIBRARY_AS_IMAGE_RESOURCE);
        if (module == IntPtr.Zero) throw new IOException("Cannot open " + path + " (error " + Marshal.GetLastWin32Error() + ")");
        try
        {
            byte[] group = Resource(module, FolderGroup, RT_GROUP_ICON);
            int count = BitConverter.ToUInt16(group, 4);
            // one frame per size, the deepest color depth wins
            var bySize = new Dictionary<int, Frame>();
            var depth = new Dictionary<int, int>();
            for (int i = 0; i < count; i++)
            {
                int at = 6 + i * 14;
                int size = group[at] == 0 ? 256 : group[at];
                int bpp = BitConverter.ToUInt16(group, at + 6);
                int id = BitConverter.ToUInt16(group, at + 12);
                if (depth.ContainsKey(size) && depth[size] >= bpp) continue;
                Frame f = Decode(Resource(module, id, RT_ICON), size);
                if (f == null) continue;
                bySize[size] = f;
                depth[size] = bpp;
            }
            if (bySize.Count == 0) throw new IOException("The stock folder icon has no usable frames.");
            var frames = new List<Frame>(bySize.Values);
            frames.Sort((a, b) => b.Size.CompareTo(a.Size));
            return frames;
        }
        finally
        {
            FreeLibrary(module);
        }
    }

    static byte[] Resource(IntPtr module, int id, int type)
    {
        IntPtr res = FindResourceW(module, (IntPtr)id, (IntPtr)type);
        if (res == IntPtr.Zero) throw new IOException("Icon resource " + id + " not found.");
        uint size = SizeofResource(module, res);
        IntPtr data = LockResource(LoadResource(module, res));
        var bytes = new byte[size];
        Marshal.Copy(data, bytes, 0, (int)size);
        return bytes;
    }

    /// <summary>A PNG frame, or a 32-bit DIB frame; null for older formats.</summary>
    static Frame Decode(byte[] blob, int size)
    {
        if (blob.Length > 8 && blob[0] == 0x89 && blob[1] == (byte)'P' && blob[2] == (byte)'N' && blob[3] == (byte)'G')
        {
            using (var ms = new MemoryStream(blob))
            using (var png = new Bitmap(ms))
                return FromBitmap(png);
        }

        int headerSize = BitConverter.ToInt32(blob, 0);
        int width = BitConverter.ToInt32(blob, 4);
        int bpp = BitConverter.ToUInt16(blob, 14);
        int compression = BitConverter.ToInt32(blob, 16);
        if (bpp != 32 || compression != 0 || width != size) return null;

        var f = new Frame(size);
        int stride = size * 4;
        bool anyAlpha = false;
        for (int y = 0; y < size; y++)
        {
            // bottom-up rows
            Buffer.BlockCopy(blob, headerSize + (size - 1 - y) * stride, f.Bgra, y * stride, stride);
        }
        for (int i = 3; i < f.Bgra.Length; i += 4) if (f.Bgra[i] != 0) { anyAlpha = true; break; }
        if (!anyAlpha)
        {
            // no alpha channel: opacity comes from the AND mask
            int maskStride = ((size + 31) / 32) * 4;
            int maskAt = headerSize + size * stride;
            for (int y = 0; y < size; y++)
                for (int x = 0; x < size; x++)
                {
                    bool transparent = (blob[maskAt + (size - 1 - y) * maskStride + x / 8] & (0x80 >> (x % 8))) != 0;
                    f.Bgra[(y * size + x) * 4 + 3] = transparent ? (byte)0 : (byte)255;
                }
        }
        return f;
    }

    // --- recoloring -------------------------------------------------------------

    static double[] Rgb(string hex)
    {
        hex = hex.Trim().TrimStart('#');
        if (hex.Length != 6) throw new ArgumentException("Bad color: #" + hex);
        return new double[]
        {
            Convert.ToInt32(hex.Substring(0, 2), 16) / 255.0,
            Convert.ToInt32(hex.Substring(2, 2), 16) / 255.0,
            Convert.ToInt32(hex.Substring(4, 2), 16) / 255.0,
        };
    }

    static double Lightness(byte b, byte g, byte r)
    {
        int max = Math.Max(r, Math.Max(g, b)), min = Math.Min(r, Math.Min(g, b));
        return (max / 255.0 + min / 255.0) / 2.0;
    }

    /// <summary>Lightness span of the opaque pixels, ignoring the extreme 1% at both ends.</summary>
    static double[] LightnessRange(Frame f)
    {
        var ls = new List<double>();
        for (int i = 0; i < f.Bgra.Length; i += 4)
            if (f.Bgra[i + 3] > 200) ls.Add(Lightness(f.Bgra[i], f.Bgra[i + 1], f.Bgra[i + 2]));
        if (ls.Count == 0) return new double[] { 0, 1 };
        ls.Sort();
        int n = ls.Count;
        return new double[] { ls[n / 100], ls[n - (n + 99) / 100 - 1] };
    }

    static Frame Recolor(Frame src, double[] range, Func<int, int, Ramp> rampAt)
    {
        var dst = new Frame(src.Size);
        double lo = range[0], span = Math.Max(range[1] - range[0], 1e-6);
        for (int y = 0; y < src.Size; y++)
            for (int x = 0; x < src.Size; x++)
            {
                int i = (y * src.Size + x) * 4;
                byte a = src.Bgra[i + 3];
                if (a == 0) continue;
                Ramp ramp = rampAt(x, y);
                double t = Math.Min(1.0, Math.Max(0.0, (Lightness(src.Bgra[i], src.Bgra[i + 1], src.Bgra[i + 2]) - lo) / span));
                double k;
                double[] c0, c1;
                if (t < 0.5) { k = t / 0.5; c0 = ramp.Dark; c1 = ramp.Mid; }
                else { k = (t - 0.5) / 0.5; c0 = ramp.Mid; c1 = ramp.Light; }
                dst.Bgra[i + 2] = Channel(c0[0], c1[0], k);
                dst.Bgra[i + 1] = Channel(c0[1], c1[1], k);
                dst.Bgra[i] = Channel(c0[2], c1[2], k);
                dst.Bgra[i + 3] = a;
            }
        return dst;
    }

    static byte Channel(double from, double to, double k)
    {
        return (byte)Math.Round((from + (to - from) * k) * 255);
    }

    // --- output -----------------------------------------------------------------

    /// <summary>.ico with PNG for 256 px and classic 32-bit DIBs (with AND mask) below.</summary>
    static void WriteIco(List<Frame> frames, string path)
    {
        var blobs = new List<byte[]>();
        foreach (Frame f in frames) blobs.Add(f.Size >= 256 ? Png(f) : Dib(f));

        string tmp = path + ".tmp";
        using (var w = new BinaryWriter(File.Create(tmp)))
        {
            w.Write((ushort)0); w.Write((ushort)1); w.Write((ushort)frames.Count);
            int offset = 6 + 16 * frames.Count;
            for (int i = 0; i < frames.Count; i++)
            {
                byte dim = frames[i].Size >= 256 ? (byte)0 : (byte)frames[i].Size;
                w.Write(dim); w.Write(dim); w.Write((byte)0); w.Write((byte)0);
                w.Write((ushort)1); w.Write((ushort)32);
                w.Write(blobs[i].Length); w.Write(offset);
                offset += blobs[i].Length;
            }
            foreach (byte[] b in blobs) w.Write(b);
        }
        // folders already pointing at this file keep working while it is replaced
        if (File.Exists(path)) File.Delete(path);
        File.Move(tmp, path);
    }

    static byte[] Dib(Frame f)
    {
        int size = f.Size, stride = size * 4, maskStride = ((size + 31) / 32) * 4;
        using (var ms = new MemoryStream())
        using (var w = new BinaryWriter(ms))
        {
            w.Write(40); w.Write(size); w.Write(size * 2); w.Write((ushort)1); w.Write((ushort)32);
            w.Write(0); w.Write(0); w.Write(0); w.Write(0); w.Write(0); w.Write(0);
            for (int y = size - 1; y >= 0; y--) w.Write(f.Bgra, y * stride, stride);
            for (int y = size - 1; y >= 0; y--)
            {
                var row = new byte[maskStride];
                for (int x = 0; x < size; x++)
                    if (f.Bgra[(y * size + x) * 4 + 3] == 0) row[x / 8] |= (byte)(0x80 >> (x % 8));
                w.Write(row);
            }
            return ms.ToArray();
        }
    }

    static byte[] Png(Frame f)
    {
        using (Bitmap bmp = ToBitmap(f))
        using (var ms = new MemoryStream())
        {
            bmp.Save(ms, ImageFormat.Png);
            return ms.ToArray();
        }
    }

    static Bitmap ToBitmap(Frame f)
    {
        var bmp = new Bitmap(f.Size, f.Size, PixelFormat.Format32bppArgb);
        BitmapData d = bmp.LockBits(new Rectangle(0, 0, f.Size, f.Size), ImageLockMode.WriteOnly, PixelFormat.Format32bppArgb);
        for (int y = 0; y < f.Size; y++) Marshal.Copy(f.Bgra, y * f.Size * 4, d.Scan0 + y * d.Stride, f.Size * 4);
        bmp.UnlockBits(d);
        return bmp;
    }

    static Frame FromBitmap(Bitmap src)
    {
        var f = new Frame(src.Width);
        // LockBits converts to straight (non-premultiplied) BGRA, unlike drawing
        BitmapData d = src.LockBits(new Rectangle(0, 0, src.Width, src.Height), ImageLockMode.ReadOnly, PixelFormat.Format32bppArgb);
        for (int y = 0; y < f.Size; y++) Marshal.Copy(d.Scan0 + y * d.Stride, f.Bgra, y * f.Size * 4, f.Size * 4);
        src.UnlockBits(d);
        return f;
    }

    static void SaveScaled(Bitmap src, int px, string path)
    {
        using (var bmp = new Bitmap(px, px, PixelFormat.Format32bppArgb))
        {
            using (Graphics g = Graphics.FromImage(bmp))
            {
                g.InterpolationMode = InterpolationMode.HighQualityBicubic;
                g.PixelOffsetMode = PixelOffsetMode.HighQuality;
                g.CompositingQuality = CompositingQuality.HighQuality;
                g.DrawImage(src, new Rectangle(0, 0, px, px));
            }
            bmp.Save(path, ImageFormat.Png);
        }
    }
}
