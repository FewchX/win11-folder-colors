# Installs Folder Colors for the current user (no admin rights needed) into
# %LOCALAPPDATA%\Programs\FolderColors:
#   - FolderColor.exe, compiled here with the C# compiler that ships with
#     Windows (.NET Framework 4); it does the actual recoloring;
#   - the icons, built here from this Windows' own folder icon;
#   - the Windows 11 context menu entry: bin\FolderColorMenu.dll, registered
#     through a local package (package\AppxManifest.xml). Windows only accepts
#     an unsigned local package with Developer Mode on;
#   - without Developer Mode (or on Windows 10), a classic context menu entry
#     in the registry instead.
# Safe to re-run: rebuilds everything and re-registers. Folders that are
# already colored keep their colors.
#
#   -Classic       install only the classic registry entry, skip the package
#   -NoGitIgnore   don't add desktop.ini to git's global ignore file

param([switch]$Classic, [switch]$NoGitIgnore)

$ErrorActionPreference = 'Stop'

$src = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'Programs\FolderColors'
$exe = Join-Path $dest 'FolderColor.exe'
$packageName = 'Local.FolderColors'
$title = 'Folder color'
$resetLabel = 'Reset to default'
$classicKey = 'HKCU:\Software\Classes\Directory\shell\FolderColors'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FolderColors'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }

function Test-DeveloperMode {
    $v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue
    return [bool]($v -and $v.AllowDevelopmentWithoutDevLicense -eq 1)
}

$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
$windows11 = $build -ge 22000

# files from a downloaded zip carry the "from the internet" mark
Get-ChildItem $src -Recurse -File | Unblock-File

# --- FolderColorMenu.dll ------------------------------------------------------------
# Release zips include it. A source download (git clone, "Code > Download ZIP")
# doesn't: build it when the toolchain is there, otherwise take the one from
# the latest release. Everything that can fail runs before the previous
# install is touched.
function Test-ZigToolchain {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { return $null }
    # the Microsoft Store "python" stub fails here too; native stderr isn't an error
    $ErrorActionPreference = 'Continue'
    & $python.Source -c 'import ziglang' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $python.Source }
    return $null
}

function Get-ReleaseDll($target) {
    $url = 'https://github.com/FewchX/win11-folder-colors/releases/latest/download/win11-folder-colors.zip'
    Write-Host "Downloading FolderColorMenu.dll from the latest release ($url)..."
    $ProgressPreference = 'SilentlyContinue' # the progress bar makes downloads slow in Windows PowerShell
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    $work = Join-Path ([IO.Path]::GetTempPath()) ('win11-folder-colors-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $work | Out-Null
    try {
        Invoke-WebRequest $url -OutFile (Join-Path $work 'release.zip') -UseBasicParsing
        Expand-Archive (Join-Path $work 'release.zip') $work
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item (Join-Path $work 'bin\FolderColorMenu.dll') $target
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$dll = Join-Path $src 'bin\FolderColorMenu.dll'
if (-not (Test-Path $dll)) {
    $python = Test-ZigToolchain
    if ($python) { & (Join-Path $src 'build.ps1') -Python $python }
    else {
        try { Get-ReleaseDll $dll }
        catch { throw "Couldn't download FolderColorMenu.dll: $_`nDownload win11-folder-colors.zip from https://github.com/FewchX/win11-folder-colors/releases/latest and run install.cmd from it." }
    }
}
if (-not (Test-Path $csc)) { throw '.NET Framework 4 C# compiler not found (csc.exe).' }

# --- release the previous install --------------------------------------------
# the registered package keeps FolderColorMenu.dll loaded in a COM surrogate;
# stop it first, or Remove-AppxPackage waits ~90 s for it to exit on its own
Get-Process dllhost -ErrorAction SilentlyContinue |
    Where-Object { try { $_.Modules.ModuleName -contains 'FolderColorMenu.dll' } catch { $false } } |
    Stop-Process -Force
if ($windows11) { Get-AppxPackage -Name $packageName | Remove-AppxPackage }

# --- build ---------------------------------------------------------------------
Write-Host 'Building FolderColor.exe...'
New-Item -ItemType Directory -Force $dest | Out-Null
& $csc /nologo /target:winexe /optimize+ /codepage:65001 /reference:System.Drawing.dll "/out:$exe" `
    (Join-Path $src 'src\FolderColor.cs') (Join-Path $src 'src\IconBuilder.cs')
if ($LASTEXITCODE -ne 0) { throw 'Building FolderColor.exe failed.' }

Write-Host 'Building the icons from the Windows folder icon...'
$colors = Get-Content (Join-Path $src 'colors.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$specs = $colors | ForEach-Object { '{0}={1}' -f $_.id, ($_.ramp -join ',') }
$errLog = Join-Path $env:TEMP 'FolderColors-build-icons.txt'
# FolderColor.exe is a GUI program: Start-Process -Wait is what waits for it
$p = Start-Process $exe -Wait -PassThru -NoNewWindow -RedirectStandardError $errLog -ArgumentList (
    @('build-icons', "`"$(Join-Path $dest 'icons')`"", "`"$(Join-Path $dest 'Assets')`"") + $specs)
if ($p.ExitCode -ne 0) { throw "Building the icons failed: $(Get-Content $errLog -Raw)" }
Remove-Item $errLog -ErrorAction SilentlyContinue

# --- files ---------------------------------------------------------------------
Copy-Item (Join-Path $src 'package\AppxManifest.xml') $dest -Force
Copy-Item $dll $dest -Force
Copy-Item (Join-Path $src 'uninstall.ps1') $dest -Force

# menu.txt feeds FolderColorMenu.dll: title, then "<id><TAB><label>" per item
$menu = @($title) + ($colors | ForEach-Object { "$($_.id)`t$($_.label)" }) + @("reset`t$resetLabel")
[IO.File]::WriteAllText((Join-Path $dest 'menu.txt'), ($menu -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))

# --- Windows 11 menu (package) -------------------------------------------------------
$packaged = $false
$answer = ''
if ($windows11 -and -not $Classic) {
    if (-not (Test-DeveloperMode)) {
        Write-Host ''
        Write-Host 'The Windows 11 context menu needs Developer Mode, which is off.' -ForegroundColor Yellow
        Write-Host 'Settings > System > For developers is opening now: turn on "Developer Mode" there.'
        Start-Process 'ms-settings:developers'
        $answer = Read-Host 'Then press Enter to continue (or type C and Enter to use the classic menu instead)'
        if ($answer -match '^\s*c') { Write-Host 'Using the classic menu.' }
        elseif (-not (Test-DeveloperMode)) { Write-Host 'Developer Mode is still off: using the classic menu.' -ForegroundColor Yellow }
    }
    if ((Test-DeveloperMode) -and $answer -notmatch '^\s*c') {
        Add-AppxPackage -Register (Join-Path $dest 'AppxManifest.xml')
        $packaged = $true
    }
}

# --- classic menu (registry) - only when the package isn't there ---------------------
# the packaged handler shows up in the classic menu as well, so both would duplicate
if (Test-Path $classicKey) { Remove-Item $classicKey -Recurse -Force }
if (-not $packaged) {
    New-Item $classicKey -Force | Out-Null
    Set-ItemProperty $classicKey -Name 'MUIVerb' -Value $title
    Set-ItemProperty $classicKey -Name 'Icon' -Value (Join-Path $dest 'icons\menu.ico')
    Set-ItemProperty $classicKey -Name 'SubCommands' -Value ''

    function Add-Item($key, $label, $icon, $command, [switch]$SeparatorBefore) {
        $k = Join-Path "$classicKey\shell" $key
        New-Item "$k\command" -Force | Out-Null
        Set-ItemProperty $k -Name 'MUIVerb' -Value $label
        Set-ItemProperty $k -Name 'Icon' -Value $icon
        if ($SeparatorBefore) { Set-ItemProperty $k -Name 'CommandFlags' -Value 0x20 -Type DWord } # ECF_SEPARATORBEFORE
        Set-ItemProperty "$k\command" -Name '(default)' -Value $command
    }

    $i = 0
    foreach ($c in $colors) {
        $i++
        # submenu items are sorted by key name, hence the numeric prefix
        Add-Item ('{0:D2}_{1}' -f $i, $c.id) $c.label (Join-Path $dest "icons\$($c.id).ico") "`"$exe`" set $($c.id) `"%1`""
    }
    Add-Item '99_reset' $resetLabel "$env:WINDIR\System32\imageres.dll,-3" "`"$exe`" reset `"%1`"" -SeparatorBefore
}

# --- git -------------------------------------------------------------------------------
# File Explorer reads a folder's icon only from the desktop.ini inside it, so a
# colored folder always has one. Listing it in git's global ignore file keeps it
# out of every repository on this PC, also ones created later in an already
# colored folder - GitHub's standard Windows .gitignore ignores it the same way.
# uninstall.ps1 removes these lines again, found by the marker comment.
$gitMarker = '# Folder Colors: folder icon files stay out of git'

function Get-GlobalGitIgnorePath {
    $git = Get-Command git -ErrorAction SilentlyContinue
    if (-not $git) { return $null }
    $ErrorActionPreference = 'Continue'
    $userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    $configured = & $git.Source config --global --get core.excludesFile 2>$null
    if ($configured) {
        $configured = "$configured".Trim()
        if ($configured.StartsWith('~')) { $configured = Join-Path $userHome $configured.Substring(1).TrimStart('/', '\') }
        return [IO.Path]::GetFullPath($configured)
    }
    # git's default when core.excludesFile isn't set
    $config = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $userHome '.config' }
    return Join-Path $config 'git\ignore'
}

if (-not $NoGitIgnore) {
    $ignoreFile = Get-GlobalGitIgnorePath
    if ($ignoreFile) {
        $existing = if (Test-Path $ignoreFile) { [IO.File]::ReadAllText($ignoreFile) } else { '' }
        if ($existing -notmatch '(?im)^\s*(\*\*/|/)?(\[Dd\]|[Dd])esktop\.ini\s*$') {
            New-Item -ItemType Directory -Force (Split-Path $ignoreFile) | Out-Null
            $prefix = if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { "`n" } else { '' }
            [IO.File]::AppendAllText($ignoreFile, "$prefix$gitMarker`n[Dd]esktop.ini`n", (New-Object Text.UTF8Encoding $false))
            # for uninstall.ps1: which file to take the lines out of
            [IO.File]::WriteAllText((Join-Path $dest 'git-ignore.txt'), $ignoreFile, (New-Object Text.UTF8Encoding $false))
            Write-Host "git: desktop.ini is now ignored in every repository ($ignoreFile)."
        }
    }
}

# --- Settings > Apps > Installed apps --------------------------------------------------
$version = ([xml](Get-Content (Join-Path $src 'package\AppxManifest.xml') -Raw)).Package.Identity.Version -replace '\.0$', ''
New-Item $uninstallKey -Force | Out-Null
Set-ItemProperty $uninstallKey -Name 'DisplayName' -Value 'Folder Colors'
Set-ItemProperty $uninstallKey -Name 'DisplayVersion' -Value $version
Set-ItemProperty $uninstallKey -Name 'Publisher' -Value 'win11-folder-colors'
Set-ItemProperty $uninstallKey -Name 'URLInfoAbout' -Value 'https://github.com/FewchX/win11-folder-colors'
Set-ItemProperty $uninstallKey -Name 'DisplayIcon' -Value (Join-Path $dest 'icons\menu.ico')
Set-ItemProperty $uninstallKey -Name 'InstallLocation' -Value $dest
Set-ItemProperty $uninstallKey -Name 'UninstallString' -Value "powershell.exe -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $dest 'uninstall.ps1')`""
Set-ItemProperty $uninstallKey -Name 'NoModify' -Value 1 -Type DWord
Set-ItemProperty $uninstallKey -Name 'NoRepair' -Value 1 -Type DWord

Write-Host ''
if ($packaged) { Write-Host "Done: right-click a folder > `"$title`"." -ForegroundColor Green }
elseif ($windows11) { Write-Host "Done: right-click a folder > Show more options > `"$title`"." -ForegroundColor Green }
else { Write-Host "Done: right-click a folder > `"$title`"." -ForegroundColor Green }
Write-Host "Installed to $dest"
