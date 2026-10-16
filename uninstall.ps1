# Removes Folder Colors: the context menu entry and %LOCALAPPDATA%\Programs\FolderColors.
# Every folder recolored through the menu (listed in colored.txt) is reset to
# the stock icon first, so nothing is left pointing at deleted icons.
# install.ps1 copies this script into the install folder, and Settings > Apps
# runs it from there.
#
#   -KeepColors   leave the folders (and the installed icons they use) as they are

param([switch]$KeepColors)

$ErrorActionPreference = 'Stop'

$dest = Join-Path $env:LOCALAPPDATA 'Programs\FolderColors'
$exe = Join-Path $dest 'FolderColor.exe'
$list = Join-Path $dest 'colored.txt'
# the install folder can't be deleted while it is the current directory
Set-Location $env:TEMP

if (-not $KeepColors -and (Test-Path $exe) -and (Test-Path $list)) {
    $folders = @(Get-Content $list -Encoding UTF8 | Where-Object { $_.Trim() -and (Test-Path -LiteralPath $_) })
    # one FolderColor.exe per batch: each run waits a few seconds for Explorer to refresh
    $batch = @()
    $length = 0
    foreach ($folder in $folders + @($null)) {
        if ($batch.Count -and ($null -eq $folder -or $length + $folder.Length -gt 20000)) {
            Start-Process -FilePath $exe -ArgumentList (@('reset') + ($batch | ForEach-Object { "`"$_`"" })) -Wait
            $batch | ForEach-Object { Write-Host "Reset: $_" }
            $batch = @()
            $length = 0
        }
        if ($null -ne $folder) {
            $batch += $folder
            $length += $folder.Length + 3
        }
    }
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
if (-not $KeepColors -and (Test-Path $dest)) { Remove-Item $dest -Recurse -Force }

Write-Host 'Folder Colors has been removed.'
