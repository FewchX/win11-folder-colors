# Removes Folder Colors: the context menu entry and %LOCALAPPDATA%\Programs\FolderColors.
# Every folder recolored through the menu (listed in colored.txt) is reset to
# the stock icon first, so nothing is left pointing at deleted icons.
# install.ps1 copies this script into the install folder, and Settings > Apps
# runs it from there.
#
#   -KeepColors   leave the colored folders as they are: only their icons and
#                 the list of them stay. To reset them later, install again
#                 and uninstall without -KeepColors.

param([switch]$KeepColors)

$ErrorActionPreference = 'Stop'

# the Appx cmdlets need Windows PowerShell; PowerShell 7 hands over to it
if ($PSVersionTable.PSEdition -eq 'Core') {
    $forward = @()
    if ($KeepColors) { $forward += '-KeepColors' }
    & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $PSCommandPath @forward
    exit $LASTEXITCODE
}

$dest = Join-Path $env:LOCALAPPDATA 'Programs\FolderColors'
$exe = Join-Path $dest 'FolderColor.exe'
$list = Join-Path $dest 'colored.txt'
# the install folder can't be deleted while it is the current directory
Set-Location $env:TEMP

if (-not $KeepColors -and (Test-Path $exe) -and (Test-Path $list)) {
    $folders = @(Get-Content $list -Encoding UTF8 | Where-Object { $_.Trim() -and (Test-Path -LiteralPath $_) })
    # one FolderColor.exe per batch: each run waits a few seconds for Explorer to refresh;
    # its errors land in a file and are shown here instead of in message boxes
    $errLog = Join-Path $env:TEMP 'FolderColors-reset.txt'
    $batch = @()
    $length = 0
    foreach ($folder in $folders + @($null)) {
        if ($batch.Count -and ($null -eq $folder -or $length + $folder.Length -gt 20000)) {
            Start-Process -FilePath $exe -ArgumentList (@('reset') + ($batch | ForEach-Object { "`"$_`"" })) -Wait -NoNewWindow -RedirectStandardError $errLog
            $batch | ForEach-Object { Write-Host "Reset: $_" }
            if ((Test-Path $errLog) -and (Get-Item $errLog).Length) { Get-Content $errLog | ForEach-Object { Write-Host $_ -ForegroundColor Yellow } }
            $batch = @()
            $length = 0
        }
        if ($null -ne $folder) {
            $batch += $folder
            $length += $folder.Length + 3
        }
    }
    Remove-Item $errLog -ErrorAction SilentlyContinue
}

$classicKey = 'HKCU:\Software\Classes\Directory\shell\FolderColors'
if (Test-Path $classicKey) { Remove-Item $classicKey -Recurse -Force }

# Windows 11 menu: the COM surrogate holding its DLL (stopped first, or the
# removal waits for it), then the local package
Get-Process dllhost -ErrorAction SilentlyContinue |
    Where-Object { try { $_.Modules.ModuleName -contains 'FolderColorMenu.dll' } catch { $false } } |
    Stop-Process -Force
Get-AppxPackage -Name 'Local.FolderColors' | Remove-AppxPackage

$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FolderColors'
if (Test-Path $uninstallKey) { Remove-Item $uninstallKey -Recurse -Force }

# the two lines install.ps1 added to git's global ignore file, if it added them
# (with -KeepColors they stay: the colored folders still have their desktop.ini)
$gitRecord = Join-Path $dest 'git-ignore.txt'
if (-not $KeepColors -and (Test-Path $gitRecord)) {
    $ignoreFile = [IO.File]::ReadAllText($gitRecord).Trim()
    if (Test-Path $ignoreFile) {
        $text = [IO.File]::ReadAllText($ignoreFile)
        $clean = $text -replace '(?m)^# Folder Colors: folder icon files stay out of git\r?\n\[Dd\]esktop\.ini(\r?\n|$)', ''
        if (-not $clean.Trim()) { Remove-Item $ignoreFile }
        elseif ($clean -ne $text) { [IO.File]::WriteAllText($ignoreFile, $clean, (New-Object Text.UTF8Encoding $false)) }
    }
}

# a reset still waiting for Explorer to refresh holds the exe
Get-Process FolderColor -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } |
    Wait-Process -Timeout 30 -ErrorAction SilentlyContinue
if (Test-Path $dest) {
    if ($KeepColors) {
        # the icons the colored folders use, and the list of them for a later uninstall
        Get-ChildItem $dest -Force | Where-Object { $_.Name -ne 'icons' -and $_.Name -ne 'colored.txt' } |
            Remove-Item -Recurse -Force
    }
    else {
        Remove-Item $dest -Recurse -Force
    }
}

Write-Host 'Folder Colors has been removed.'
