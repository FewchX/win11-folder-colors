# Installs Folder Colors for the current user (no admin rights needed) into
# %LOCALAPPDATA%\Programs\FolderColors:
#   - FolderColor.exe, compiled here with the C# compiler that ships with
#     Windows (.NET Framework 4); it does the actual recoloring;
#   - the icons, built here from this Windows' own folder icon;
#   - the Windows 11 context menu entry: bin\<x64|arm64>\FolderColorMenu.dll,
#     registered through a local package (package\AppxManifest.xml). Windows
#     only accepts an unsigned local package with Developer Mode on;
#   - without Developer Mode (or on Windows 10), a classic context menu entry
#     in the registry instead.
# Safe to re-run: rebuilds everything and re-registers. Folders that are
# already colored keep their colors.
#
#   -Classic       install only the classic registry entry, skip the package
#   -NoGitIgnore   don't add desktop.ini to git's global ignore file

param([switch]$Classic, [switch]$NoGitIgnore)

$ErrorActionPreference = 'Stop'

# the Appx cmdlets need Windows PowerShell; PowerShell 7 hands over to it
if ($PSVersionTable.PSEdition -eq 'Core') {
    $forward = @()
    if ($Classic) { $forward += '-Classic' }
    if ($NoGitIgnore) { $forward += '-NoGitIgnore' }
    & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @forward
    exit $LASTEXITCODE
}

$src = $PSScriptRoot
$dest = Join-Path $env:LOCALAPPDATA 'Programs\FolderColors'
$exe = Join-Path $dest 'FolderColor.exe'
$packageName = 'Local.FolderColors'
$title = 'Folder color'
$resetLabel = 'Reset to default'
$classicKey = 'HKCU:\Software\Classes\Directory\shell\FolderColors'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FolderColors'
$repo = 'FewchX/win11-folder-colors'
$csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
if (-not (Test-Path $csc)) { $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework\v4.0.30319\csc.exe' }

function Test-DeveloperMode {
    $v = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue
    return [bool]($v -and $v.AllowDevelopmentWithoutDevLicense -eq 1)
}

$build = [int](Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows NT\CurrentVersion').CurrentBuildNumber
$windows11 = $build -ge 22000
# the PC's CPU, also when this PowerShell runs emulated (x64 on an ARM64 PC);
# the menu DLL has to match File Explorer's
$arch = switch ((Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE) {
    'AMD64' { 'x64' }
    'ARM64' { 'arm64' }
    default { $null } # 32-bit Windows 10: the classic menu needs no DLL
}
$packageWanted = $windows11 -and -not $Classic -and $arch
$version = ([xml](Get-Content (Join-Path $src 'package\AppxManifest.xml') -Raw)).Package.Identity.Version -replace '\.0$', ''

# files from a downloaded zip carry the "from the internet" mark; the DLL
# would keep it in the install folder
foreach ($item in 'install.ps1', 'uninstall.ps1', 'build.ps1', 'colors.json', 'bin', 'src', 'package') {
    $path = Join-Path $src $item
    if (Test-Path $path) { Get-ChildItem $path -File -Recurse | Unblock-File }
}

# --- colors.json ---------------------------------------------------------------
# checked first: a typo there must not cost the working install
$colors = Get-Content (Join-Path $src 'colors.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$colors = @($colors)
if ($colors.Count -eq 0) { throw 'colors.json lists no colors.' }
$seen = @{}
foreach ($c in $colors) {
    $id = "$($c.id)"
    # the id names an icon file, and "menu" and "reset" are taken
    if ($id -cnotmatch '^[a-z0-9-]{1,32}$' -or $id -eq 'menu' -or $id -eq 'reset') {
        throw "colors.json: bad id '$id'. Use lowercase letters, digits and '-', and not 'menu' or 'reset'."
    }
    if ($seen.ContainsKey($id)) { throw "colors.json: the id '$id' is listed twice." }
    $seen[$id] = $true
    if (-not "$($c.label)".Trim() -or "$($c.label)" -match '[\t\r\n]') { throw "colors.json: '$id' needs a one-line label." }
    $ramp = @($c.ramp)
    if ($ramp.Count -ne 3 -or @($ramp | Where-Object { "$_" -notmatch '^#[0-9a-fA-F]{6}$' }).Count) {
        throw "colors.json: '$id' needs a ramp of three colors like #3b82f6."
    }
}

# --- FolderColorMenu.dll ------------------------------------------------------------
# Release zips include it. A source download (git clone, "Code > Download ZIP")
# doesn't: build it when the toolchain is there, otherwise take the one from
# the matching release.
function Test-ZigToolchain {
    $python = Get-Command python -ErrorAction SilentlyContinue
    if (-not $python) { return $null }
    # the Microsoft Store "python" stub fails here too; native stderr isn't an error
    $ErrorActionPreference = 'Continue'
    & $python.Source -c 'import ziglang' 2>$null | Out-Null
    if ($LASTEXITCODE -eq 0) { return $python.Source }
    return $null
}

# Downloads the release zip of this version (the latest one if this version
# isn't released yet) and checks it against the SHA-256 GitHub lists for it.
function Get-ReleaseDll($target) {
    $ProgressPreference = 'SilentlyContinue' # the progress bar makes downloads slow in Windows PowerShell
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
    try { $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/tags/v$version" -UseBasicParsing }
    catch { $release = Invoke-RestMethod "https://api.github.com/repos/$repo/releases/latest" -UseBasicParsing }
    $asset = @($release.assets | Where-Object { $_.name -eq 'win11-folder-colors.zip' })[0]
    if (-not $asset -or "$($asset.digest)" -notmatch '^sha256:([0-9a-f]{64})$') { throw "Release $($release.tag_name) has no checksum for win11-folder-colors.zip." }
    $expected = $Matches[1]

    Write-Host "Downloading FolderColorMenu.dll from release $($release.tag_name)..."
    $work = Join-Path ([IO.Path]::GetTempPath()) ('win11-folder-colors-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $work | Out-Null
    try {
        $zip = Join-Path $work 'release.zip'
        Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "Checksum mismatch: expected $expected, got $actual." }
        Expand-Archive $zip (Join-Path $work 'x')
        $released = Join-Path $work "x\bin\$arch\FolderColorMenu.dll"
        # releases before 1.2 had only the x64 DLL, in bin\
        if (-not (Test-Path $released) -and $arch -eq 'x64') { $released = Join-Path $work 'x\bin\FolderColorMenu.dll' }
        if (-not (Test-Path $released)) { throw "Release $($release.tag_name) has no FolderColorMenu.dll for $arch." }
        New-Item -ItemType Directory -Force (Split-Path $target) | Out-Null
        Copy-Item $released $target
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}

$dll = Join-Path $src "bin\$arch\FolderColorMenu.dll"
if ($packageWanted -and -not (Test-Path $dll)) {
    $python = Test-ZigToolchain
    if ($python) { & (Join-Path $src 'build.ps1') -Python $python -Arch $arch }
    else {
        try { Get-ReleaseDll $dll }
        catch { throw "Couldn't download FolderColorMenu.dll: $_`nDownload win11-folder-colors.zip from https://github.com/$repo/releases/latest and run install.cmd from it." }
    }
}
if (-not (Test-Path $csc)) { throw '.NET Framework 4 C# compiler not found (csc.exe).' }

# --- build -----------------------------------------------------------------------
# Into a staging folder: the previous install stays untouched until everything
# here has worked. The icons go straight to their place; each file is swapped
# in one step, so folders that use them never see one missing.
$stage = Join-Path ([IO.Path]::GetTempPath()) ('FolderColors-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
New-Item -ItemType Directory $stage | Out-Null
try {
    Write-Host 'Building FolderColor.exe...'
    $built = Join-Path $stage 'FolderColor.exe'
    & $csc /nologo /target:winexe /optimize+ /codepage:65001 /reference:System.Drawing.dll "/out:$built" `
        (Join-Path $src 'src\FolderColor.cs') (Join-Path $src 'src\IconBuilder.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Building FolderColor.exe failed.' }

    Write-Host 'Building the icons from the Windows folder icon...'
    New-Item -ItemType Directory -Force $dest | Out-Null
    $specs = $colors | ForEach-Object { '{0}={1}' -f $_.id, ($_.ramp -join ',') }
    $errLog = Join-Path $stage 'build-icons.txt'
    # FolderColor.exe is a GUI program: Start-Process -Wait is what waits for it
    $p = Start-Process $built -Wait -PassThru -NoNewWindow -RedirectStandardError $errLog -ArgumentList (
        @('build-icons', "`"$(Join-Path $dest 'icons')`"", "`"$(Join-Path $dest 'Assets')`"") + $specs)
    if ($p.ExitCode -ne 0) { throw "Building the icons failed: $(Get-Content $errLog -Raw -Encoding UTF8)" }

    # --- release the previous install --------------------------------------------
    # a recolor still waiting for Explorer to refresh holds the old exe
    $running = { Get-Process FolderColor -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } }
    & $running | Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
    if (& $running) { throw 'FolderColor.exe is still running (is a "Folder color" message box open?). Close it and run the installer again.' }
    # the registered package keeps FolderColorMenu.dll loaded in a COM surrogate;
    # stop it first, or Remove-AppxPackage waits ~90 s for it to exit on its own
    Get-Process dllhost -ErrorAction SilentlyContinue |
        Where-Object { try { $_.Modules.ModuleName -contains 'FolderColorMenu.dll' } catch { $false } } |
        Stop-Process -Force
    if ($windows11) { Get-AppxPackage -Name $packageName | Remove-AppxPackage }

    # --- files -------------------------------------------------------------------
    Copy-Item $built $exe -Force
    Copy-Item (Join-Path $src 'uninstall.ps1') $dest -Force
    if ($packageWanted) {
        Copy-Item $dll $dest -Force
        # the package declares the CPU its DLL is for
        $manifest = [IO.File]::ReadAllText((Join-Path $src 'package\AppxManifest.xml'))
        $manifest = $manifest -replace 'ProcessorArchitecture="[^"]*"', "ProcessorArchitecture=`"$arch`""
        [IO.File]::WriteAllText((Join-Path $dest 'AppxManifest.xml'), $manifest, (New-Object Text.UTF8Encoding $false))
    }
    else {
        # left from an earlier install with the package
        Remove-Item (Join-Path $dest 'FolderColorMenu.dll'), (Join-Path $dest 'AppxManifest.xml') -ErrorAction SilentlyContinue
    }
}
finally {
    Remove-Item $stage -Recurse -Force -ErrorAction SilentlyContinue
}

# menu.txt feeds FolderColorMenu.dll: title, then "<id><TAB><label>" per item
$menu = @($title) + ($colors | ForEach-Object { "$($_.id)`t$($_.label)" }) + @("reset`t$resetLabel")
[IO.File]::WriteAllText((Join-Path $dest 'menu.txt'), ($menu -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))

# Folders colored by an earlier version point at the icons by full path, user
# name included; this rewrites them to %LOCALAPPDATA%\... like new ones.
$refreshLog = Join-Path $env:TEMP 'FolderColors-refresh.txt'
Start-Process $exe -ArgumentList 'refresh' -Wait -NoNewWindow -RedirectStandardError $refreshLog
Remove-Item $refreshLog -ErrorAction SilentlyContinue

# --- Windows 11 menu (package) -------------------------------------------------------
$packaged = $false
$answer = ''
if ($packageWanted) {
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
        try {
            Add-AppxPackage -Register (Join-Path $dest 'AppxManifest.xml')
            $packaged = $true
        }
        catch {
            Write-Host "Windows didn't accept the menu package ($($_.Exception.Message.Trim())). Using the classic menu instead." -ForegroundColor Yellow
        }
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
# Written even before git is installed: git reads that file once it is.
# uninstall.ps1 removes these lines again, found by the marker comment.
$gitMarker = '# Folder Colors: folder icon files stay out of git'
$git = Get-Command git -ErrorAction SilentlyContinue
# git prints paths in UTF-8: read them that way, or non-English folder names break
$consoleEncoding = [Console]::OutputEncoding
try { [Console]::OutputEncoding = New-Object Text.UTF8Encoding $false } catch { }

function Get-GlobalGitIgnorePath {
    $userHome = if ($env:HOME) { $env:HOME } else { $env:USERPROFILE }
    if ($git) {
        $ErrorActionPreference = 'Continue'
        # --includes: also a core.excludesFile set in a file included from .gitconfig
        $configured = & $git.Source config --global --includes --get core.excludesFile 2>$null
        if ($LASTEXITCODE -eq 0 -and "$configured".Trim()) {
            $configured = "$configured".Trim()
            if ($configured.StartsWith('~')) { $configured = Join-Path $userHome $configured.Substring(1).TrimStart('/', '\') }
            return [IO.Path]::GetFullPath($configured)
        }
    }
    # git's default when core.excludesFile isn't set
    $config = if ($env:XDG_CONFIG_HOME) { $env:XDG_CONFIG_HOME } else { Join-Path $userHome '.config' }
    return Join-Path $config 'git\ignore'
}

$gitRecord = Join-Path $dest 'git-ignore.txt'
$ignored = $false
if (-not $NoGitIgnore) {
    $ignoreFile = Get-GlobalGitIgnorePath
    $existing = if (Test-Path $ignoreFile) { [IO.File]::ReadAllText($ignoreFile) } else { '' }
    $ignored = $existing -match '(?im)^\s*(\*\*/)?(\[Dd\]|[Dd])esktop\.ini\s*$'
    if (-not $ignored) {
        New-Item -ItemType Directory -Force (Split-Path $ignoreFile) | Out-Null
        $prefix = if ($existing.Length -gt 0 -and -not $existing.EndsWith("`n")) { "`n" } else { '' }
        [IO.File]::AppendAllText($ignoreFile, "$prefix$gitMarker`n[Dd]esktop.ini`n", (New-Object Text.UTF8Encoding $false))
        $existing = [IO.File]::ReadAllText($ignoreFile)
        $ignored = $true
        Write-Host "git: desktop.ini is now ignored in every repository ($ignoreFile)."
    }
    # for uninstall.ps1: which file to take the lines out of (only lines this installer added)
    if ($existing.Contains($gitMarker)) { [IO.File]::WriteAllText($gitRecord, $ignoreFile, (New-Object Text.UTF8Encoding $false)) }
}

# Version 1.0 also put desktop.ini into the .git/info/exclude of each repository
# with a colored folder. The global ignore file covers those now, so the old
# lines go. git itself finds the repository (and skips ones it doesn't trust).
$list = Join-Path $dest 'colored.txt'
if ($ignored -and $git -and (Test-Path $list)) {
    $ErrorActionPreference = 'Continue'
    $cleaned = @{}
    foreach ($line in Get-Content $list -Encoding UTF8) {
        $folder = ($line -split "`t")[0].Trim() # "path TAB id"
        if (-not $folder -or -not (Test-Path -LiteralPath $folder)) { continue }
        $common = & $git.Source -C $folder rev-parse --path-format=absolute --git-common-dir 2>$null
        if ($LASTEXITCODE -ne 0 -or -not "$common".Trim()) { continue }
        $exclude = Join-Path ("$common".Trim() -replace '/', '\') 'info\exclude'
        if ($cleaned.ContainsKey($exclude) -or -not (Test-Path -LiteralPath $exclude)) { continue }
        $cleaned[$exclude] = $true
        $text = [IO.File]::ReadAllText($exclude)
        $clean = $text -replace '(?m)^# folder icon \(FolderColor\)\r?\ndesktop\.ini(\r?\n|$)', ''
        if ($clean -ne $text) { [IO.File]::WriteAllText($exclude, $clean, (New-Object Text.UTF8Encoding $false)) }
    }
    $ErrorActionPreference = 'Stop'
}
try { [Console]::OutputEncoding = $consoleEncoding } catch { }

# --- Settings > Apps > Installed apps --------------------------------------------------
New-Item $uninstallKey -Force | Out-Null
Set-ItemProperty $uninstallKey -Name 'DisplayName' -Value 'Folder Colors'
Set-ItemProperty $uninstallKey -Name 'DisplayVersion' -Value $version
Set-ItemProperty $uninstallKey -Name 'Publisher' -Value 'win11-folder-colors'
Set-ItemProperty $uninstallKey -Name 'URLInfoAbout' -Value "https://github.com/$repo"
Set-ItemProperty $uninstallKey -Name 'DisplayIcon' -Value (Join-Path $dest 'icons\menu.ico')
Set-ItemProperty $uninstallKey -Name 'InstallLocation' -Value $dest
Set-ItemProperty $uninstallKey -Name 'UninstallString' -Value "`"$(Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe')`" -NoProfile -ExecutionPolicy Bypass -File `"$(Join-Path $dest 'uninstall.ps1')`""
Set-ItemProperty $uninstallKey -Name 'NoModify' -Value 1 -Type DWord
Set-ItemProperty $uninstallKey -Name 'NoRepair' -Value 1 -Type DWord

Write-Host ''
if ($packaged) { Write-Host "Done: right-click a folder > `"$title`"." -ForegroundColor Green }
elseif ($windows11) { Write-Host "Done: right-click a folder > Show more options > `"$title`"." -ForegroundColor Green }
else { Write-Host "Done: right-click a folder > `"$title`"." -ForegroundColor Green }
Write-Host "Installed to $dest"
