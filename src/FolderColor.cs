// FolderColor.exe - recolors a folder's icon from the Explorer context menu.
//
//   FolderColor.exe set <color> <folder>...   use icons\<color>.ico next to the exe
//   FolderColor.exe reset <folder>...         back to the stock folder icon
//   FolderColor.exe build-icons ...           see IconBuilder.cs (run by install.ps1)
//
// Called by the classic menu (one folder per process) and by the Windows 11
// menu handler FolderColorMenu.dll (all selected folders in one process).
//
// Uses the standard Windows mechanism (the same one as Properties > Customize
// > Change Icon): an IconResource line in the folder's hidden desktop.ini plus
// the folder's read-only bit, which only tells Explorer to read desktop.ini.
// Nothing else inside the folder is touched. If the folder lives in a git
// repository, desktop.ini goes into that repo's local .git/info/exclude so it
// never shows up as an untracked file.
//
// Built by install.ps1 with the csc of .NET Framework 4, which ships with
// Windows (C# 5: no string interpolation, no ?. etc.).

using System;
using System.Collections.Generic;
using System.IO;
using System.Runtime.InteropServices;
using System.Text;

static class FolderColor
{
    const string Title = "Folder color";
    const string Section = "[.ShellClassInfo]";

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

    static readonly string AppDir = AppDomain.CurrentDomain.BaseDirectory;

    static int Main(string[] args)
    {
        if (args.Length > 0 && args[0] == "build-icons")
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

        bool set = args.Length >= 3 && args[0] == "set";
        bool reset = args.Length >= 2 && args[0] == "reset";
        if (!set && !reset)
        {
            Fail("Usage:\n  FolderColor.exe set <color> <folder>...\n  FolderColor.exe reset <folder>...");
            return 2;
        }

        // one bad folder must not stop the rest of a multi-selection
        var errors = new List<string>();
        var changed = new List<string>();
        for (int i = set ? 2 : 1; i < args.Length; i++)
        {
            try
            {
                string folder = NormalizeFolder(args[i]);
                if (set) Set(folder, args[1]);
                else Reset(folder);
                changed.Add(folder);
            }
            catch (UnauthorizedAccessException)
            {
                errors.Add("No permission to change this folder: " + args[i]);
            }
            catch (Exception e)
            {
                errors.Add(e.Message);
            }
        }
        if (changed.Count > 0) Notify(changed);
        if (errors.Count > 0)
        {
            Fail(string.Join("\n", errors.ToArray()));
            return 1;
        }
        return 0;
    }

    static void Fail(string message)
    {
        MessageBoxW(IntPtr.Zero, message, Title, MB_ICONERROR);
    }

    static string NormalizeFolder(string raw)
    {
        // "%1" on a path ending in a backslash arrives with a stray quote
        string path = Path.GetFullPath(raw.Trim().TrimEnd('"'));
        if (path.Length > 3) path = path.TrimEnd('\\');
        if (!Directory.Exists(path)) throw new DirectoryNotFoundException("Folder not found: " + path);
        return path;
    }

    // --- set / reset ------------------------------------------------------

    // The icon a folder had before its first recolor (Documents, Downloads and
    // other special folders have one) is kept under this key, which Explorer
    // ignores, so that reset can put it back. Several lines are joined with
    // '|', which can't occur in a path.
    const string OriginalKey = "FolderColorsOriginal";

    static void Set(string folder, string color)
    {
        string icon = Path.Combine(Path.Combine(AppDir, "icons"), color + ".ico");
        if (!File.Exists(icon)) throw new FileNotFoundException("No icon for color \"" + color + "\": " + icon);

        string ini = Path.Combine(folder, "desktop.ini");
        List<string> lines = ReadIni(ini);
        int at = FindOrAddSection(lines);
        List<string> previous = RemoveIconKeys(lines, at);
        if (previous.Count > 0 && FindKey(lines, at, OriginalKey) < 0 && !IsOurIcon(previous))
            lines.Insert(at + 1, OriginalKey + "=" + string.Join("|", previous.ToArray()));
        lines.Insert(at + 1, "IconResource=" + icon + ",0");
        WriteIni(ini, lines);

        PathMakeSystemFolderW(folder);
        ApplyThroughShell(folder, icon, 0);
        ExcludeFromGit(folder);
        Track(folder, true);
    }

    static void Reset(string folder)
    {
        string ini = Path.Combine(folder, "desktop.ini");
        if (File.Exists(ini))
        {
            List<string> original = new List<string>();
            List<string> lines = ReadIni(ini);
            int at = FindSection(lines);
            int key = at >= 0 ? FindKey(lines, at, OriginalKey) : -1;
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
        Track(folder, false);
    }

    static bool IsOurIcon(List<string> iconLines)
    {
        string ours = Path.Combine(AppDir, "icons") + "\\";
        foreach (string l in iconLines)
            if (l.IndexOf(ours, StringComparison.OrdinalIgnoreCase) >= 0) return true;
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
            System.Threading.Thread.Sleep(delay);
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
        // a hidden+system file can't be overwritten in place
        if (File.Exists(path)) File.SetAttributes(path, FileAttributes.Normal);
        // UTF-16 LE with BOM: what Explorer itself writes, safe for any path
        File.WriteAllText(path, string.Join("\r\n", lines) + "\r\n", Encoding.Unicode);
        File.SetAttributes(path, FileAttributes.Hidden | FileAttributes.System);
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

    // --- git ----------------------------------------------------------------

    static void ExcludeFromGit(string folder)
    {
        try
        {
            string common = FindGitCommonDir(folder);
            if (common == null) return;
            string info = Path.Combine(common, "info");
            string exclude = Path.Combine(info, "exclude");
            if (File.Exists(exclude))
            {
                foreach (string l in File.ReadAllLines(exclude))
                {
                    string t = l.Trim();
                    if (t == "desktop.ini" || t == "/desktop.ini" || t == "**/desktop.ini") return;
                }
            }
            Directory.CreateDirectory(info);
            string prefix = File.Exists(exclude) && !EndsWithNewline(exclude) ? "\n" : "";
            File.AppendAllText(exclude, prefix + "# folder icon (FolderColor)\ndesktop.ini\n", new UTF8Encoding(false));
        }
        catch (Exception)
        {
            // best effort - the icon itself is already applied
        }
    }

    static bool EndsWithNewline(string path)
    {
        byte[] b = File.ReadAllBytes(path);
        return b.Length == 0 || b[b.Length - 1] == (byte)'\n';
    }

    /// <summary>Nearest enclosing repo's common git dir (handles worktrees and submodules).</summary>
    static string FindGitCommonDir(string folder)
    {
        for (DirectoryInfo d = new DirectoryInfo(folder); d != null; d = d.Parent)
        {
            string dotGit = Path.Combine(d.FullName, ".git");
            string gitDir = null;
            if (Directory.Exists(dotGit))
            {
                gitDir = dotGit;
            }
            else if (File.Exists(dotGit))
            {
                string content = File.ReadAllText(dotGit).Trim();
                if (!content.StartsWith("gitdir:")) return null;
                gitDir = Path.GetFullPath(Path.Combine(d.FullName, content.Substring(7).Trim()));
            }
            if (gitDir == null) continue;

            string commonFile = Path.Combine(gitDir, "commondir");
            if (File.Exists(commonFile))
                return Path.GetFullPath(Path.Combine(gitDir, File.ReadAllText(commonFile).Trim()));
            return gitDir;
        }
        return null;
    }

    // --- bookkeeping ----------------------------------------------------------

    /// <summary>colored.txt lists every recolored folder so uninstall can reset them.</summary>
    static void Track(string folder, bool colored)
    {
        try
        {
            string list = Path.Combine(AppDir, "colored.txt");
            var paths = new List<string>();
            if (File.Exists(list))
                foreach (string l in File.ReadAllLines(list, Encoding.UTF8))
                    if (l.Trim().Length > 0 && !string.Equals(l.Trim(), folder, StringComparison.OrdinalIgnoreCase))
                        paths.Add(l.Trim());
            if (colored) paths.Add(folder);
            File.WriteAllLines(list, paths.ToArray(), new UTF8Encoding(false));
        }
        catch (Exception)
        {
            // bookkeeping only
        }
    }
}
