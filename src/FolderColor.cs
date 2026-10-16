// FolderColor.exe - recolors a folder's icon from the Explorer context menu.
//
//   FolderColor.exe set <color> <folder>...   use icons\<color>.ico next to the exe
//   FolderColor.exe reset <folder>...         back to the folder's previous icon
//   FolderColor.exe refresh                   point colored folders at this install (run by install.ps1)
//   FolderColor.exe reset-all                 reset every colored folder (run by uninstall.ps1)
//   FolderColor.exe build-icons ...           see IconBuilder.cs (run by install.ps1)
//
// Called by the classic menu (one folder per process) and by the Windows 11
// menu handler FolderColorMenu.dll (all selected folders in one process).
// colored.txt next to the exe lists every colored folder, with its file
// system id, so that a folder renamed or moved since is still found.
//
// Uses the standard Windows mechanism (the same one as Properties > Customize
// > Change Icon): an IconResource line in the folder's hidden desktop.ini plus
// the folder's read-only bit, which only tells Explorer to read desktop.ini.
// Nothing else inside the folder is read or touched.
//
// Built by install.ps1 with the csc of .NET Framework 4, which ships with
// Windows (C# 5: no string interpolation, no ?. etc.).

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using Microsoft.Win32.SafeHandles;

static class FolderColor
{
    const string Title = "Folder color";
    const string Section = "[.ShellClassInfo]";

    // The icon a folder had before its first recolor (Documents, Downloads and
    // other special folders have one) is kept under this key, which Explorer
    // ignores, so that reset can put it back. Several lines are joined with
    // '|', which can't occur in a path.
    const string OriginalKey = "FolderColorsOriginal";

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern void SHChangeNotify(int eventId, uint flags, string item1, IntPtr item2);

    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    static extern bool PathMakeSystemFolderW(string path);

    [DllImport("shlwapi.dll", CharSet = CharSet.Unicode)]
    static extern bool PathUnmakeSystemFolderW(string path);

    [DllImport("user32.dll", CharSet = CharSet.Unicode)]
    static extern int MessageBoxW(IntPtr hwnd, string text, string caption, uint type);

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct SHFOLDERCUSTOMSETTINGS
    {
        public uint dwSize; public uint dwMask; public IntPtr pvid;
        public IntPtr pszWebViewTemplate; public uint cchWebViewTemplate; public IntPtr pszWebViewTemplateVersion;
        public IntPtr pszInfoTip; public uint cchInfoTip; public IntPtr pclsid; public uint dwFlags;
        [MarshalAs(UnmanagedType.LPWStr)] public string pszIconFile; public uint cchIconFile; public int iIconIndex;
        public IntPtr pszLogo; public uint cchLogo;
    }

    [DllImport("shell32.dll", CharSet = CharSet.Unicode)]
    static extern int SHGetSetFolderCustomSettings(ref SHFOLDERCUSTOMSETTINGS settings, string path, uint readWrite);

    const uint FCSM_ICONFILE = 0x10;
    const uint FCS_FORCEWRITE = 0x2;

    const int SHCNE_UPDATEDIR = 0x00001000;
    const int SHCNE_UPDATEITEM = 0x00002000;
    const uint SHCNF_PATHW = 0x0005;
    const uint SHCNF_FLUSH = 0x1000;
    const uint MB_ICONERROR = 0x10;

    [DllImport("kernel32.dll")]
    static extern IntPtr GetStdHandle(int which);

    [DllImport("kernel32.dll")]
    static extern uint GetFileType(IntPtr handle);

    const int STD_ERROR_HANDLE = -12;
    const uint FILE_TYPE_DISK = 1;
    const uint FILE_TYPE_PIPE = 3;

    [StructLayout(LayoutKind.Sequential, CharSet = CharSet.Unicode)]
    struct WIN32_FIND_DATA
    {
        public uint dwFileAttributes;
        public System.Runtime.InteropServices.ComTypes.FILETIME ftCreationTime, ftLastAccessTime, ftLastWriteTime;
        public uint nFileSizeHigh, nFileSizeLow, dwReserved0, dwReserved1;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 260)] public string cFileName;
        [MarshalAs(UnmanagedType.ByValTStr, SizeConst = 14)] public string cAlternateFileName;
    }

    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    static extern IntPtr FindFirstFileW(string name, out WIN32_FIND_DATA data);

    [DllImport("kernel32.dll")]
    static extern bool FindClose(IntPtr handle);

    const uint FILE_ATTRIBUTE_REPARSE_POINT = 0x400;
    const uint REPARSE_TAG_NAME_SURROGATE = 0x20000000; // symbolic links and junctions

    static readonly string AppDir = AppDomain.CurrentDomain.BaseDirectory;
    static readonly string IconsDir = Path.Combine(AppDir, "icons");

    static int Main(string[] args)
    {
        // what the scripts read back from a redirected stdout/stderr: UTF-8, so
        // folder names in any language survive (without a handle these go nowhere)
        Console.SetOut(new StreamWriter(Console.OpenStandardOutput(), new UTF8Encoding(false)) { AutoFlush = true });
        Console.SetError(new StreamWriter(Console.OpenStandardError(), new UTF8Encoding(false)) { AutoFlush = true });

        string command = args.Length > 0 ? args[0] : "";
        if (command == "build-icons")
        {
            try
            {
                return IconBuilder.Run(args);
            }
            catch (Exception e)
            {
                // install.ps1 reads this from the redirected stderr
                Console.Error.WriteLine(e.Message);
                return 1;
            }
        }

        int first; // index of the first folder argument
        if (command == "set" && args.Length >= 3) first = 2;
        else if (command == "reset" && args.Length >= 2) first = 1;
        else if ((command == "refresh" || command == "reset-all") && args.Length == 1) first = 1;
        else
        {
            Fail("Usage:\n  FolderColor.exe set <color> <folder>...\n  FolderColor.exe reset <folder>...");
            return 2;
        }
        // the id becomes part of a file name: only plain ids, never a path
        if (command == "set" && !IsColorId(args[1]))
        {
            Fail("Unknown color: " + args[1]);
            return 2;
        }

        var errors = new List<string>();
        var changed = new List<string>();
        // Two quick menu clicks start two processes: one at a time keeps their
        // edits of desktop.ini and colored.txt from interleaving.
        using (var mutex = new Mutex(false, @"Local\FolderColors"))
        {
            if (!Acquire(mutex))
            {
                Fail("Another Folder Colors operation is still running. Try again in a moment.");
                return 1;
            }
            try
            {
                var colored = ColoredList.Load(Path.Combine(AppDir, "colored.txt"));
                var folders = new List<string>();
                for (int i = first; i < args.Length; i++) folders.Add(args[i]);
                if (command == "refresh" || command == "reset-all")
                {
                    // folders renamed or moved since they were colored
                    colored.Relocate();
                    if (command == "reset-all") folders.AddRange(colored.Paths);
                }
                if (command == "refresh")
                {
                    foreach (string folder in colored.Paths)
                    {
                        try
                        {
                            Refresh(folder);
                        }
                        catch (Exception)
                        {
                            // a folder that's gone or out of reach keeps its old line
                        }
                    }
                }
                // one bad folder must not stop the rest of a multi-selection
                foreach (string raw in folders)
                {
                    try
                    {
                        if (command == "reset-all" && !Directory.Exists(raw))
                        {
                            colored.Remove(raw); // deleted since
                            continue;
                        }
                        string folder = NormalizeFolder(raw);
                        if (command == "set") Set(folder, args[1], colored);
                        else Reset(folder, colored);
                        changed.Add(folder);
                        // uninstall.ps1 lists what it reset
                        if (command == "reset-all") Console.Out.WriteLine(folder);
                    }
                    catch (UnauthorizedAccessException)
                    {
                        errors.Add("No permission to change this folder: " + raw);
                    }
                    catch (Exception e)
                    {
                        errors.Add(e.Message);
                    }
                }
                colored.Save();
            }
            finally
            {
                mutex.ReleaseMutex();
            }
        }
        // outside the lock: this part only waits for Explorer
        if (changed.Count > 0) Notify(changed);
        if (errors.Count > 0)
        {
            Fail(string.Join("\n", errors.ToArray()));
            return 1;
        }
        return 0;
    }

    static bool Acquire(Mutex mutex)
    {
        try
        {
            return mutex.WaitOne(TimeSpan.FromSeconds(30));
        }
        catch (AbandonedMutexException)
        {
            // the previous owner died mid-way; the lock is ours now
            return true;
        }
    }

    static void Fail(string message)
    {
        // run by a script with stderr going to a file or pipe (the tests): no dialog
        uint type = GetFileType(GetStdHandle(STD_ERROR_HANDLE));
        if (type == FILE_TYPE_DISK || type == FILE_TYPE_PIPE)
        {
            Console.Error.WriteLine(message);
            return;
        }
        MessageBoxW(IntPtr.Zero, message, Title, MB_ICONERROR);
    }

    internal static bool IsColorId(string id)
    {
        if (id.Length == 0 || id.Length > 32) return false;
        foreach (char c in id)
            if (!((c >= 'a' && c <= 'z') || (c >= '0' && c <= '9') || c == '-')) return false;
        return true;
    }

    static string NormalizeFolder(string raw)
    {
        // "%1" on a path ending in a backslash arrives with a stray quote (and
        // whatever followed it); a full path never starts or ends with a space
        string path = Path.GetFullPath(raw.Trim().TrimEnd('"').TrimEnd());
        if (path.Length > 3) path = path.TrimEnd('\\');
        if (!Directory.Exists(path)) throw new DirectoryNotFoundException("Folder not found: " + path);
        // a drive's icon doesn't come from desktop.ini
        if (string.Equals(Path.GetPathRoot(path).TrimEnd('\\'), path.TrimEnd('\\'), StringComparison.OrdinalIgnoreCase))
            throw new ArgumentException("A whole drive can't be colored: " + path);
        return path;
    }

    // --- set / reset / refresh ----------------------------------------------

    static void Set(string folder, string color, ColoredList colored)
    {
        string icon = Path.Combine(IconsDir, color + ".ico");
        if (!File.Exists(icon)) throw new FileNotFoundException("No icon for color \"" + color + "\": " + icon);
        string reference = PortablePath(icon);

        string ini = Path.Combine(folder, "desktop.ini");
        RefuseLink(ini);
        List<string> lines = ReadIni(ini);
        int at = FindOrAddSection(lines);
        List<string> previous = RemoveIconKeys(lines, at);
        if (previous.Count > 0 && FindKey(lines, at, OriginalKey) < 0 && !IsOurIcon(previous))
            lines.Insert(at + 1, OriginalKey + "=" + string.Join("|", previous.ToArray()));
        lines.Insert(at + 1, "IconResource=" + reference + ",0");
        WriteIni(ini, lines);

        PathMakeSystemFolderW(folder);
        ApplyThroughShell(folder, reference, 0);
        colored.Add(folder);
    }

    static void Reset(string folder, ColoredList colored)
    {
        string ini = Path.Combine(folder, "desktop.ini");
        RefuseLink(ini);
        List<string> lines = ReadIni(ini);
        int at = FindSection(lines);
        int key = at >= 0 ? FindKey(lines, at, OriginalKey) : -1;
        // Only an icon this program set is undone. Any other one stays, so
        // Reset on Documents, Desktop, a OneDrive folder or a folder customized
        // in Properties changes nothing.
        if (at >= 0 && (key >= 0 || IsOurIcon(RemoveIconKeys(new List<string>(lines), at))))
        {
            var original = new List<string>();
            if (key >= 0) original.AddRange(ValueOf(lines[key]).Split('|'));

            string iconFile;
            int iconIndex;
            ParseIcon(original, out iconFile, out iconIndex);
            ApplyThroughShell(folder, iconFile, iconIndex);

            // the shell call above rewrote desktop.ini: start from its result
            lines = ReadIni(ini);
            at = FindSection(lines);
            if (at >= 0)
            {
                RemoveIconKeys(lines, at);
                key = FindKey(lines, at, OriginalKey);
                if (key >= 0) lines.RemoveAt(key);
                for (int i = original.Count - 1; i >= 0; i--) lines.Insert(at + 1, original[i]);
                if (SectionIsEmpty(lines, at)) lines.RemoveAt(at);
            }
            if (lines.TrueForAll(l => l.Trim().Length == 0))
            {
                if (File.Exists(ini))
                {
                    File.SetAttributes(ini, FileAttributes.Normal);
                    File.Delete(ini);
                }
                PathUnmakeSystemFolderW(folder);
            }
            else
            {
                WriteIni(ini, lines);
            }
        }
        colored.Remove(folder);
    }

    /// <summary>
    /// Rewrites a colored folder's icon line in the current form: earlier
    /// versions wrote the full path with the user name in it.
    /// </summary>
    static void Refresh(string folder)
    {
        string ini = Path.Combine(folder, "desktop.ini");
        if (!File.Exists(ini) || IsLink(ini)) return;
        List<string> lines = ReadIni(ini);
        int at = FindSection(lines);
        int key = at >= 0 ? FindKey(lines, at, "IconResource") : -1;
        if (key < 0 || !IsOurIcon(new List<string> { lines[key] })) return;

        string file;
        int index;
        ParseIcon(new List<string> { lines[key] }, out file, out index);
        string color = Path.GetFileNameWithoutExtension(file);
        string icon = Path.Combine(IconsDir, color + ".ico");
        if (!IsColorId(color) || !File.Exists(icon)) return;
        string line = "IconResource=" + PortablePath(icon) + ",0";
        if (lines[key].Trim() == line) return;
        lines[key] = line;
        WriteIni(ini, lines);
    }

    /// <summary>
    /// A desktop.ini that is a symbolic link (say, from a cloned repository or
    /// an extracted archive) would make every write below land in the file it
    /// points to, anywhere on the disk.
    /// </summary>
    static void RefuseLink(string ini)
    {
        if (IsLink(ini)) throw new IOException("This folder's desktop.ini is a link to another file, so it was left alone: " + ini);
    }

    /// <summary>
    /// True for a symbolic link or junction. OneDrive placeholders are reparse
    /// points too but not links, so the tag decides, not the attribute.
    /// </summary>
    static bool IsLink(string path)
    {
        WIN32_FIND_DATA data;
        IntPtr find = FindFirstFileW(path, out data);
        if (find == new IntPtr(-1)) return false;
        FindClose(find);
        return (data.dwFileAttributes & FILE_ATTRIBUTE_REPARSE_POINT) != 0
            && (data.dwReserved0 & REPARSE_TAG_NAME_SURROGATE) != 0;
    }

    /// <summary>
    /// %LOCALAPPDATA%\... instead of C:\Users\name\AppData\Local\...: desktop.ini
    /// travels with its folder (cloud sync, archives, shared drives) and
    /// shouldn't carry the user name. Explorer expands the variable, so on any
    /// PC with Folder Colors installed the folder shows the same color.
    /// </summary>
    static string PortablePath(string path)
    {
        string local = Environment.GetFolderPath(Environment.SpecialFolder.LocalApplicationData).TrimEnd('\\');
        if (local.Length > 0 && path.StartsWith(local + "\\", StringComparison.OrdinalIgnoreCase))
            return "%LOCALAPPDATA%" + path.Substring(local.Length);
        return path;
    }

    /// <summary>An icon of this install, or of an earlier one in another folder.</summary>
    static bool IsOurIcon(List<string> iconLines)
    {
        string ours = IconsDir + "\\";
        foreach (string l in iconLines)
        {
            string expanded = Environment.ExpandEnvironmentVariables(l);
            if (expanded.IndexOf(ours, StringComparison.OrdinalIgnoreCase) >= 0
                || expanded.IndexOf(@"\FolderColors\icons\", StringComparison.OrdinalIgnoreCase) >= 0)
                return true;
        }
        return false;
    }

    /// <summary>Icon file and index from IconResource=, or IconFile= with IconIndex=; "" when none.</summary>
    static void ParseIcon(List<string> iconLines, out string file, out int index)
    {
        file = "";
        index = 0;
        foreach (string l in iconLines)
        {
            string key = KeyOf(l), value = ValueOf(l);
            if (key.Equals("IconResource", StringComparison.OrdinalIgnoreCase))
            {
                int comma = value.LastIndexOf(',');
                int parsed;
                if (comma > 0 && int.TryParse(value.Substring(comma + 1).Trim(), out parsed))
                {
                    file = value.Substring(0, comma).Trim();
                    index = parsed;
                }
                else
                {
                    file = value;
                }
                return;
            }
            if (key.Equals("IconFile", StringComparison.OrdinalIgnoreCase)) file = value;
            if (key.Equals("IconIndex", StringComparison.OrdinalIgnoreCase)) int.TryParse(value, out index);
        }
    }

    /// <summary>
    /// Re-applies the icon through the shell's own API (what Properties >
    /// Customize uses). desktop.ini is already written by then; this call is
    /// what makes a running Explorer drop its cached copy of it - without it,
    /// views in Medium/Large icons keep the old folder thumbnail.
    /// An empty icon clears it (reset).
    /// </summary>
    static void ApplyThroughShell(string folder, string icon, int index)
    {
        var s = new SHFOLDERCUSTOMSETTINGS();
        s.dwSize = (uint)Marshal.SizeOf(s);
        s.dwMask = FCSM_ICONFILE;
        s.pszIconFile = icon;
        s.iIconIndex = index;
        SHGetSetFolderCustomSettings(ref s, folder, FCS_FORCEWRITE);
    }

    // Repeated passes: an open Medium/Large-icons view answers the first one by
    // dropping the folder's content-preview thumbnail (showing the plain stock
    // folder) and only picks up the new icon on a refresh that arrives after it
    // has finished that work; one sent too soon is merged into the first.
    // The process runs detached from the menu, so waiting here costs nothing.
    static readonly int[] RefreshDelaysMs = { 0, 1200, 1800 };

    static void Notify(IEnumerable<string> folders)
    {
        var parents = new HashSet<string>(StringComparer.OrdinalIgnoreCase);
        foreach (string f in folders)
        {
            string p = Path.GetDirectoryName(f);
            if (p != null) parents.Add(p);
        }
        foreach (int delay in RefreshDelaysMs)
        {
            Thread.Sleep(delay);
            foreach (string f in folders) SHChangeNotify(SHCNE_UPDATEITEM, SHCNF_PATHW | SHCNF_FLUSH, f, IntPtr.Zero);
            foreach (string p in parents) SHChangeNotify(SHCNE_UPDATEDIR, SHCNF_PATHW | SHCNF_FLUSH, p, IntPtr.Zero);
        }
    }

    // --- desktop.ini --------------------------------------------------------

    static List<string> ReadIni(string path)
    {
        var lines = new List<string>();
        if (!File.Exists(path)) return lines;
        byte[] bytes = File.ReadAllBytes(path);
        Encoding enc = Encoding.Default; // ANSI unless a BOM says otherwise
        int skip = 0;
        if (bytes.Length >= 2 && bytes[0] == 0xFF && bytes[1] == 0xFE) { enc = Encoding.Unicode; skip = 2; }
        else if (bytes.Length >= 3 && bytes[0] == 0xEF && bytes[1] == 0xBB && bytes[2] == 0xBF) { enc = Encoding.UTF8; skip = 3; }
        string text = enc.GetString(bytes, skip, bytes.Length - skip);
        lines.AddRange(text.Replace("\r\n", "\n").Split('\n'));
        while (lines.Count > 0 && lines[lines.Count - 1].Trim().Length == 0) lines.RemoveAt(lines.Count - 1);
        return lines;
    }

    static void WriteIni(string path, List<string> lines)
    {
        // UTF-16 LE with BOM: what Explorer itself writes, safe for any path
        byte[] bom = Encoding.Unicode.GetPreamble();
        byte[] text = Encoding.Unicode.GetBytes(string.Join("\r\n", lines.ToArray()) + "\r\n");
        // Rewritten in place: replacing a hidden file needs its attributes
        // cleared first, and a failed write would then leave it visible.
        if (File.Exists(path) && (File.GetAttributes(path) & FileAttributes.ReadOnly) != 0)
            File.SetAttributes(path, File.GetAttributes(path) & ~FileAttributes.ReadOnly);
        using (var f = new FileStream(path, FileMode.OpenOrCreate, FileAccess.Write, FileShare.Read))
        {
            f.Write(bom, 0, bom.Length);
            f.Write(text, 0, text.Length);
            f.SetLength(f.Position);
        }
        File.SetAttributes(path, File.GetAttributes(path) | FileAttributes.Hidden | FileAttributes.System);
    }

    static int FindSection(List<string> lines)
    {
        for (int i = 0; i < lines.Count; i++)
            if (string.Equals(lines[i].Trim(), Section, StringComparison.OrdinalIgnoreCase)) return i;
        return -1;
    }

    static int FindOrAddSection(List<string> lines)
    {
        int at = FindSection(lines);
        if (at >= 0) return at;
        lines.Insert(0, Section);
        return 0;
    }

    static bool IsSectionHeader(string line)
    {
        string t = line.Trim();
        return t.StartsWith("[") && t.EndsWith("]");
    }

    static string KeyOf(string line)
    {
        int eq = line.IndexOf('=');
        return (eq >= 0 ? line.Substring(0, eq) : line).Trim();
    }

    static string ValueOf(string line)
    {
        int eq = line.IndexOf('=');
        return eq >= 0 ? line.Substring(eq + 1).Trim() : "";
    }

    static int FindKey(List<string> lines, int sectionAt, string key)
    {
        for (int i = sectionAt + 1; i < lines.Count && !IsSectionHeader(lines[i]); i++)
            if (KeyOf(lines[i]).Equals(key, StringComparison.OrdinalIgnoreCase)) return i;
        return -1;
    }

    /// <summary>Removes the section's icon lines and returns them (trimmed).</summary>
    static List<string> RemoveIconKeys(List<string> lines, int sectionAt)
    {
        var removed = new List<string>();
        for (int i = sectionAt + 1; i < lines.Count && !IsSectionHeader(lines[i]); )
        {
            string key = KeyOf(lines[i]);
            if (key.Equals("IconResource", StringComparison.OrdinalIgnoreCase)
                || key.Equals("IconFile", StringComparison.OrdinalIgnoreCase)
                || key.Equals("IconIndex", StringComparison.OrdinalIgnoreCase))
            {
                removed.Add(lines[i].Trim());
                lines.RemoveAt(i);
            }
            else
            {
                i++;
            }
        }
        return removed;
    }

    static bool SectionIsEmpty(List<string> lines, int sectionAt)
    {
        for (int i = sectionAt + 1; i < lines.Count && !IsSectionHeader(lines[i]); i++)
            if (lines[i].Trim().Length > 0) return false;
        return true;
    }

    // --- bookkeeping ----------------------------------------------------------

    /// <summary>
    /// colored.txt lists every recolored folder so uninstall can reset them:
    /// "path TAB id" per line, the id from FolderId (lines of 1.0/1.1 have
    /// only the path). Loaded once per run and saved atomically, under the
    /// process lock.
    /// </summary>
    sealed class ColoredList
    {
        sealed class Entry
        {
            public string Path, Id;
        }

        readonly string path;
        readonly List<Entry> entries = new List<Entry>();
        bool dirty;

        ColoredList(string path) { this.path = path; }

        /// <summary>A snapshot: the list may change while it is walked.</summary>
        public List<string> Paths
        {
            get
            {
                var all = new List<string>();
                foreach (Entry e in entries) all.Add(e.Path);
                return all;
            }
        }

        public static ColoredList Load(string path)
        {
            var list = new ColoredList(path);
            try
            {
                if (File.Exists(path))
                {
                    foreach (string l in File.ReadAllLines(path, Encoding.UTF8))
                    {
                        string[] parts = l.Split('\t');
                        string folder = parts[0].Trim();
                        string id = parts.Length > 1 && parts[1].Trim().Length > 0 ? parts[1].Trim() : null;
                        if (folder.Length > 0 && list.IndexOf(folder, id) < 0) list.entries.Add(new Entry { Path = folder, Id = id });
                    }
                }
            }
            catch (Exception)
            {
                // bookkeeping only
            }
            return list;
        }

        int IndexOf(string folder, string id)
        {
            for (int i = 0; i < entries.Count; i++)
                if ((id != null && entries[i].Id == id) || string.Equals(entries[i].Path, folder, StringComparison.OrdinalIgnoreCase))
                    return i;
            return -1;
        }

        public void Add(string folder)
        {
            string id = FolderId.Of(folder);
            int i = IndexOf(folder, id);
            if (i < 0)
            {
                entries.Add(new Entry { Path = folder, Id = id });
                dirty = true;
            }
            else if (entries[i].Path != folder || entries[i].Id != id)
            {
                // colored again after a move: one line, the current path
                entries[i].Path = folder;
                entries[i].Id = id;
                dirty = true;
            }
        }

        public void Remove(string folder)
        {
            string id = FolderId.Of(folder);
            for (int i = entries.Count - 1; i >= 0; i--)
            {
                if ((id != null && entries[i].Id == id) || string.Equals(entries[i].Path, folder, StringComparison.OrdinalIgnoreCase))
                {
                    entries.RemoveAt(i);
                    dirty = true;
                }
            }
        }

        /// <summary>
        /// Points entries at where their folders are now: a folder renamed or
        /// moved on the same drive keeps its id. Lines from 1.0/1.1 get their id.
        /// </summary>
        public void Relocate()
        {
            foreach (Entry e in entries)
            {
                string id = FolderId.Of(e.Path);
                if (id != null && (e.Id == null || id == e.Id))
                {
                    if (e.Id == null)
                    {
                        e.Id = id;
                        dirty = true;
                    }
                    continue;
                }
                if (e.Id == null) continue;
                string moved = FolderId.Find(e.Id, e.Path);
                if (moved != null && moved != e.Path)
                {
                    e.Path = moved;
                    dirty = true;
                }
            }
        }

        public void Save()
        {
            if (!dirty) return;
            try
            {
                var lines = new List<string>();
                foreach (Entry e in entries) lines.Add(e.Id != null ? e.Path + "\t" + e.Id : e.Path);
                // a crash mid-write leaves the old list, never half of one
                string tmp = path + ".tmp";
                File.WriteAllLines(tmp, lines.ToArray(), new UTF8Encoding(false));
                if (File.Exists(path)) File.Replace(tmp, path, null, true);
                else File.Move(tmp, path);
            }
            catch (Exception)
            {
                // bookkeeping only
            }
        }
    }

    /// <summary>
    /// A folder's identity on its drive: the volume serial number and the
    /// 128-bit file id, which stay the same when the folder is renamed or moved
    /// on that drive (NTFS, ReFS). Written as "serial:id" in hex.
    /// </summary>
    static class FolderId
    {
        [StructLayout(LayoutKind.Explicit, Size = 24)]
        struct FILE_ID_INFO
        {
            [FieldOffset(0)] public ulong VolumeSerialNumber;
            [FieldOffset(8)] public ulong IdLow;
            [FieldOffset(16)] public ulong IdHigh;
        }

        [StructLayout(LayoutKind.Explicit, Size = 24)]
        struct FILE_ID_DESCRIPTOR
        {
            [FieldOffset(0)] public uint dwSize;
            [FieldOffset(4)] public int Type;
            [FieldOffset(8)] public ulong IdLow;
            [FieldOffset(16)] public ulong IdHigh;
        }

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern SafeFileHandle CreateFileW(string name, uint access, uint share, IntPtr security, uint disposition, uint flags, IntPtr template);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool GetFileInformationByHandleEx(SafeFileHandle file, int infoClass, out FILE_ID_INFO info, uint size);

        [DllImport("kernel32.dll", SetLastError = true)]
        static extern SafeFileHandle OpenFileById(SafeFileHandle volumeHint, ref FILE_ID_DESCRIPTOR id, uint access, uint share, IntPtr security, uint flags);

        [DllImport("kernel32.dll", CharSet = CharSet.Unicode, SetLastError = true)]
        static extern uint GetFinalPathNameByHandleW(SafeFileHandle file, StringBuilder path, uint size, uint flags);

        const uint FILE_READ_ATTRIBUTES = 0x80;
        const uint FILE_SHARE_ALL = 0x7; // read, write, delete: never in anyone's way
        const uint OPEN_EXISTING = 3;
        const uint FILE_FLAG_BACKUP_SEMANTICS = 0x02000000; // needed to open a folder
        const int FileIdInfo = 18;
        const int ExtendedFileIdType = 2;

        static SafeFileHandle Open(string folder)
        {
            return CreateFileW(folder, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, IntPtr.Zero, OPEN_EXISTING, FILE_FLAG_BACKUP_SEMANTICS, IntPtr.Zero);
        }

        static string IdOf(SafeFileHandle handle)
        {
            FILE_ID_INFO info;
            if (!GetFileInformationByHandleEx(handle, FileIdInfo, out info, (uint)Marshal.SizeOf(typeof(FILE_ID_INFO)))) return null;
            if (info.IdLow == 0 && info.IdHigh == 0) return null;
            return string.Format("{0:x16}:{1:x16}{2:x16}", info.VolumeSerialNumber, info.IdHigh, info.IdLow);
        }

        /// <summary>The id of an existing folder, or null (missing, or a drive without stable ids).</summary>
        public static string Of(string folder)
        {
            try
            {
                using (SafeFileHandle h = Open(folder))
                    return h.IsInvalid ? null : IdOf(h);
            }
            catch (Exception)
            {
                return null;
            }
        }

        /// <summary>Where the folder with this id is now, on the drive of its old path; null if gone.</summary>
        public static string Find(string id, string oldPath)
        {
            try
            {
                string[] parts = id.Split(':');
                if (parts.Length != 2 || parts[1].Length != 32) return null;
                var d = new FILE_ID_DESCRIPTOR();
                d.dwSize = (uint)Marshal.SizeOf(typeof(FILE_ID_DESCRIPTOR));
                d.Type = ExtendedFileIdType;
                d.IdHigh = Convert.ToUInt64(parts[1].Substring(0, 16), 16);
                d.IdLow = Convert.ToUInt64(parts[1].Substring(16), 16);

                using (SafeFileHandle volume = Open(Path.GetPathRoot(oldPath)))
                {
                    if (volume.IsInvalid) return null;
                    using (SafeFileHandle h = OpenFileById(volume, ref d, FILE_READ_ATTRIBUTES, FILE_SHARE_ALL, IntPtr.Zero, FILE_FLAG_BACKUP_SEMANTICS))
                    {
                        // the same id on another drive is another folder
                        if (h.IsInvalid || IdOf(h) != id) return null;
                        var buffer = new StringBuilder(32768);
                        uint n = GetFinalPathNameByHandleW(h, buffer, (uint)buffer.Capacity, 0);
                        if (n == 0 || n >= buffer.Capacity) return null;
                        string found = buffer.ToString();
                        if (found.StartsWith(@"\\?\UNC\")) found = @"\\" + found.Substring(8);
                        else if (found.StartsWith(@"\\?\")) found = found.Substring(4);
                        return Directory.Exists(found) ? found : null;
                    }
                }
            }
            catch (Exception)
            {
                return null;
            }
        }
    }
}
