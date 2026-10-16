# Folder Colors for Windows 11

Color your folders from the right-click menu. Pick one of 8 colors, and the folder gets a
recolored version of the native Windows 11 folder icon. Nothing inside the folder changes.

![Colored folders in File Explorer](docs/screenshots/folders.png)

![The "Folder color" submenu in the Windows 11 context menu](docs/screenshots/menu.png)

- Lives in the **new Windows 11 context menu**, no "Show more options" needed.
- Works on several selected folders at once.
- **Reset to default** brings back the stock icon.
- No admin rights, no background process, nothing runs until you click the menu.
- Folders inside git repositories stay clean: `git status` doesn't change.

## Install

**Quick install**: open PowerShell and run

```powershell
irm https://raw.githubusercontent.com/FewchX/win11-folder-colors/main/get.ps1 | iex
```

**Or manually**: download `win11-folder-colors.zip` from the
[latest release](https://github.com/FewchX/win11-folder-colors/releases/latest), extract it and
double-click `install.cmd`. If Windows shows "Windows protected your PC", click
**More info → Run anyway**: the scripts aren't signed.

### Developer Mode

The new Windows 11 menu only shows entries from installed app packages. Folder Colors
registers a small local package for that, and Windows accepts an unsigned local package only
with **Developer Mode** on:

**Settings → System → For developers → Developer Mode**

If it's off, the installer opens that page and waits for you. If you'd rather not turn it on,
type `C` there: you get the same menu under **Show more options** instead. The installer never
changes this setting itself.

Requirements: Windows 11 (Windows 10 works too, with the classic menu). Everything else the
installer needs is part of Windows.

## Use

Right-click a folder (or several) → **Folder color** → pick a color. The new icon shows up
within a second or two. An open window with large icons first shows the plain folder for a
moment, then the color.

## Uninstall

**Settings → Apps → Installed apps → Folder Colors → Uninstall**, or run `uninstall.cmd` from
the zip. Every folder you colored is reset to the stock icon first. To remove the menu and keep
the colors, run `uninstall.ps1 -KeepColors`.

## Is it safe for my files?

Yes. Folder Colors uses the same mechanism as **Properties → Customize → Change Icon**
in File Explorer, which Windows itself uses for Documents, Downloads and other special folders:

1. A hidden `desktop.ini` file in the folder, with one `IconResource=` line pointing to the icon.
2. The folder's **read-only** attribute. On folders this doesn't make anything read-only; it only
   tells File Explorer to read `desktop.ini`.

Files and subfolders inside are never read, moved or modified, and you can keep working in
the folder as usual. If the folder already had a `desktop.ini` (Documents, Downloads and other
special folders do), everything else in it is kept, and **Reset to default** brings back the
folder's own icon.

If the folder is inside a git repository, `desktop.ini` is added to that repository's local
`.git/info/exclude`, so it never shows up as a new file and never gets committed. That file is
local to your clone and isn't shared.

Things worth knowing:

- **Scripts that delete the folder itself.** Some programs refuse to delete a read-only folder:
  .NET's `Directory.Delete` and Python's `shutil.rmtree` delete everything inside but fail on the
  folder itself with "Access denied". File Explorer, `rd /s` and `Remove-Item -Force` work
  normally. Don't color folders that tools delete and recreate, like `build` or `dist`, or reset
  the color first.
- **Cloud folders.** In OneDrive or Dropbox, `desktop.ini` syncs too. On a computer without
  Folder Colors the folder just looks like a normal folder.
- **Where the icons live.** Colored folders point to the icons in
  `%LOCALAPPDATA%\Programs\FolderColors\icons`. Uninstall resets the folders before it deletes
  the icons.

## Change the colors

Edit [`colors.json`](colors.json) and run the installer again. Each color has an `id` (icon
file name), a `label` (menu text) and a `ramp` of three colors: the darkest edge, the main
color and the highlight. Folders you already colored use the same icon files, but File
Explorer may keep showing the old shade until it refreshes its icon cache.

## How it works

| Part | What it does |
|---|---|
| `src/FolderColor.cs` | `FolderColor.exe`: writes `desktop.ini`, sets the attribute, updates `.git/info/exclude`, tells Explorer to refresh. Also builds the icons. |
| `src/IconBuilder.cs` | Recolors the stock folder icon (`imageres.dll`) at every size with a gradient map that keeps the native shading. |
| `src/FolderColorMenu.cpp` | `FolderColorMenu.dll`: the `IExplorerCommand` handler behind the menu. It only builds the menu and starts `FolderColor.exe`. |
| `package/AppxManifest.xml` | The local package that gives the DLL the identity the Windows 11 menu requires. |
| `install.ps1` / `uninstall.ps1` | Install into `%LOCALAPPDATA%\Programs\FolderColors` for the current user. |

The repository contains no Microsoft artwork. The installer builds the icons on your PC from
your own Windows folder icon, so they always match your Windows version. `FolderColor.exe` is
compiled during install with the C# compiler that ships with Windows (.NET Framework 4).
Only `FolderColorMenu.dll` comes prebuilt in the release zip, built by
[GitHub Actions](.github/workflows/release.yml) from the source in this repository.

## Build from source

Installing from a clone needs `bin\FolderColorMenu.dll`. `install.ps1` builds it automatically
if Python with the [ziglang](https://pypi.org/project/ziglang/) package is available
(`pip install ziglang==0.16.0`, which includes a complete C++ toolchain, no Visual Studio
needed):

```powershell
git clone https://github.com/FewchX/win11-folder-colors
cd win11-folder-colors
.\build.ps1      # optional: install.ps1 runs it if the DLL is missing
.\install.ps1
```

Pushing a `v*` tag builds the release zip and publishes it on GitHub.

## Troubleshooting

- **The menu entry is missing.** Check that Developer Mode is on and run the installer again.
  Without Developer Mode, the entry is under **Show more options**.
- **The color doesn't show.** Press F5 in that window. Thumbnail views sometimes hold on to the
  old picture for a moment.
- **"Running scripts is disabled on this system".** Use `install.cmd`, or run
  `powershell -ExecutionPolicy Bypass -File install.ps1`.

## License

[MIT](LICENSE)
