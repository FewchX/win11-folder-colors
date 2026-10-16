# Tests install.ps1 and uninstall.ps1 for real: installs Folder Colors for the
# current user, uses the Windows 11 menu through the installed package,
# uninstalls, and checks what each step leaves behind - also with -Classic and
# -KeepColors. Only runs on CI, on a fresh virtual machine each time: on a PC
# it would replace the install there. Needs Developer Mode, which the workflow
# turns on first, and build.ps1 -Tests.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-install-tests.ps1

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $env:GITHUB_ACTIONS) { throw 'These tests install and uninstall Folder Colors for the current user, so they only run on CI.' }

$root = Split-Path $PSScriptRoot
$arch = Get-NativeArch
$harness = Join-Path $PSScriptRoot "bin\$arch\menu-harness.exe"
$dest = Join-Path $env:LOCALAPPDATA 'Programs\FolderColors'
$exe = Join-Path $dest 'FolderColor.exe'
$classicKey = 'HKCU:\Software\Classes\Directory\shell\FolderColors'
$uninstallKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Uninstall\FolderColors'
$manifestVersion = ([xml](Get-Content (Join-Path $root 'package\AppxManifest.xml') -Raw)).Package.Identity.Version
$colors = Get-Content (Join-Path $root 'colors.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$colors = @($colors)
$git = Get-Command git -ErrorAction SilentlyContinue

# install.ps1 or the installed uninstall.ps1, each in its own Windows
# PowerShell like install.cmd and Settings run them; the output goes to the log
function Invoke-Script($script, [string[]]$arguments) {
    Write-Host "  > $(Split-Path $script -Leaf) $arguments"
    $ErrorActionPreference = 'Continue'
    $output = @(& (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File $script @arguments 2>&1 |
        ForEach-Object { "$_" })
    $code = $LASTEXITCODE
    $output | ForEach-Object { Write-Host "    | $_" }
    return [pscustomobject]@{ Code = $code; Output = $output }
}

# the installed FolderColor.exe, errors to a file instead of a message box
function Invoke-FolderColor([string[]]$arguments) {
    $quoted = $arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    $p = Start-Process $exe -ArgumentList $quoted -Wait -PassThru -NoNewWindow -RedirectStandardError (Join-Path $work 'stderr.txt')
    return $p.ExitCode
}

function Invoke-Harness([string[]]$arguments) {
    $out = Join-Path $work 'harness.txt'
    $quoted = $arguments | ForEach-Object { if ($_ -match '\s') { "`"$_`"" } else { $_ } }
    $p = Start-Process $harness -ArgumentList $quoted -PassThru -NoNewWindow -RedirectStandardOutput $out
    $null = $p.Handle # keeps the exit code readable after the process ends
    if (-not $p.WaitForExit(120000)) { $p.Kill(); throw "menu-harness $arguments hangs." }
    $lines = @([IO.File]::ReadAllLines($out))
    $lines | ForEach-Object { Write-Host "    | $_" }
    return [pscustomobject]@{ Code = $p.ExitCode; Lines = $lines }
}

# FolderColor.exe started by a menu click; one still running after two
# minutes is stuck in an error message box
function Wait-FolderColor {
    $running = @(Get-Process FolderColor -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
    $running | Wait-Process -Timeout 120 -ErrorAction SilentlyContinue
    $stuck = @($running | Where-Object { -not $_.HasExited })
    $stuck | Stop-Process -Force
    return $stuck.Count -eq 0
}

function New-Folder($name) {
    $path = Join-Path $work $name
    New-Item -ItemType Directory -Force $path | Out-Null
    return $path
}

function Get-IconLine($folder) {
    $ini = Join-Path $folder 'desktop.ini'
    if (Test-Path -LiteralPath $ini) { return [IO.File]::ReadAllLines($ini) | Where-Object { $_ -like 'IconResource=*' } }
    return $null
}

function Test-Reset($folder) {
    return $null -eq (Get-IconLine $folder) -and -not ((Get-Item -LiteralPath $folder -Force).Attributes -band [IO.FileAttributes]::ReadOnly)
}

function Get-Colored {
    $list = Join-Path $dest 'colored.txt'
    if (Test-Path $list) { return @(Get-Content $list -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split "`t")[0] }) }
    return @()
}

function Test-GitIgnored {
    $ErrorActionPreference = 'Continue'
    & $git.Source -C $repo check-ignore -q desktop.ini 2>$null
    return $LASTEXITCODE -eq 0
}

function Test-Machine($file, $machine) {
    $bytes = [IO.File]::ReadAllBytes($file)
    return [BitConverter]::ToUInt16($bytes, [BitConverter]::ToInt32($bytes, 0x3C) + 4) -eq $machine
}

function Test-Uninstalled {
    return -not (Get-AppxPackage -Name 'Local.FolderColors') -and -not (Test-Path $classicKey) -and -not (Test-Path $uninstallKey)
}

$work = New-TestFolder 'folder-colors-install-test-'
try {
    $unlock = Get-ItemProperty 'HKLM:\SOFTWARE\Microsoft\Windows\CurrentVersion\AppModelUnlock' -ErrorAction SilentlyContinue
    if (-not ($unlock -and $unlock.AllowDevelopmentWithoutDevLicense -eq 1)) { throw 'Developer Mode is off; the workflow turns it on before these tests.' }
    if (-not (Test-Path $harness)) { throw "$harness is missing: run build.ps1 -Tests first." }
    if (-not (Test-Uninstalled) -or (Test-Path $dest)) { throw 'Folder Colors is installed already.' }
    if ($git) {
        $repo = New-Folder 'repo'
        & $git.Source init -q $repo
        $ignoredBefore = Test-GitIgnored
    }

    Write-Host "Install ($arch)"
    $r = Invoke-Script (Join-Path $root 'install.ps1')
    Check 'install.ps1 succeeds' ($r.Code -eq 0)
    $package = Get-AppxPackage -Name 'Local.FolderColors'
    Check 'the menu package is registered' ($null -ne $package)
    Check "the package is for $arch, with the manifest's version" ("$($package.Architecture)" -eq $arch -and "$($package.Version)" -eq $manifestVersion)
    $files = @('FolderColor.exe', 'FolderColorMenu.dll', 'AppxManifest.xml', 'menu.txt', 'uninstall.ps1', 'icons\menu.ico') + ($colors | ForEach-Object { "icons\$($_.id).ico" })
    Check 'every file is in place' (@($files | Where-Object { -not (Test-Path (Join-Path $dest $_)) }).Count -eq 0)
    $machine = if ($arch -eq 'arm64') { 0xAA64 } else { 0x8664 }
    Check "the menu DLL is the $arch build" (Test-Machine (Join-Path $dest 'FolderColorMenu.dll') $machine)
    Check 'no classic menu entry next to the package' (-not (Test-Path $classicKey))
    $entry = Get-ItemProperty $uninstallKey -ErrorAction SilentlyContinue
    Check 'Settings > Apps lists it, with the right version' ($entry -and $entry.DisplayVersion -eq ($manifestVersion -replace '\.0$', '') -and
        $entry.UninstallString -like "*$(Join-Path $dest 'uninstall.ps1')*")
    if ($git) { Check 'git ignores desktop.ini' (Test-GitIgnored) }

    Write-Host 'The Windows 11 menu, through the package'
    $folder = New-Folder 'menu\folder'
    $r = Invoke-Harness @('com', 'describe', $folder)
    Check 'COM creates the menu from the package' ($r.Code -eq 0 -and $r.Lines.Count -gt 0 -and $r.Lines[0] -like "root`tFolder color`t*")
    $r = Invoke-Harness @('com', 'invoke', 'Red', $folder)
    $finished = Wait-FolderColor
    Check 'a click colors the folder' ($r.Code -eq 0 -and $finished -and (Get-IconLine $folder) -match '\\icons\\red\.ico,0$')
    # FolderColor.exe runs with the package's identity here: its writes must not be virtualized
    Check 'colored.txt in the install folder lists it' ((Get-Colored) -contains $folder)

    Write-Host 'Install again over it'
    $kept = New-Folder 'kept'
    Check 'FolderColor.exe colors a folder' ((Invoke-FolderColor @('set', 'orange', $kept)) -eq 0)
    $r = Invoke-Script (Join-Path $root 'install.ps1')
    Check 'a second install succeeds' ($r.Code -eq 0 -and $null -ne (Get-AppxPackage -Name 'Local.FolderColors'))
    Check 'colored folders keep their colors' ((Get-IconLine $kept) -match '\\icons\\orange\.ico,0$' -and (Get-IconLine $folder) -match '\\icons\\red\.ico,0$')

    Write-Host 'Uninstall'
    # moved after the last install, so only uninstall can find it
    $moved = Join-Path $work 'moved\elsewhere\kept'
    New-Item -ItemType Directory -Force (Split-Path $moved) | Out-Null
    Move-Item -LiteralPath $kept -Destination $moved
    $r = Invoke-Script (Join-Path $dest 'uninstall.ps1')
    Check 'uninstall.ps1 succeeds' ($r.Code -eq 0)
    Check 'it resets the folders it colored' (Test-Reset $folder)
    Check 'it finds and resets a folder moved since' ((Test-Reset $moved) -and $r.Output -contains "Reset: $moved")
    Check 'the package, the menu and the Settings entry are gone' (Test-Uninstalled)
    Check 'the install folder is gone' (-not (Test-Path $dest))
    if ($git -and -not $ignoredBefore) { Check 'the git ignore lines are gone' (-not (Test-GitIgnored)) }

    Write-Host 'Classic menu (-Classic)'
    $r = Invoke-Script (Join-Path $root 'install.ps1') @('-Classic')
    Check 'install.ps1 -Classic succeeds' ($r.Code -eq 0)
    Check 'no package, no menu DLL' (-not (Get-AppxPackage -Name 'Local.FolderColors') -and -not (Test-Path (Join-Path $dest 'FolderColorMenu.dll')))
    $items = @(Get-ChildItem "$classicKey\shell" -ErrorAction SilentlyContinue)
    Check 'the classic entry has one item per color, then reset' ($items.Count -eq $colors.Count + 1)
    $command = (Get-ItemProperty "$classicKey\shell\01_$($colors[0].id)\command" -ErrorAction SilentlyContinue).'(default)'
    Check 'its items run the installed FolderColor.exe' ($command -eq "`"$exe`" set $($colors[0].id) `"%1`"")

    Write-Host 'Uninstall -KeepColors'
    $keep = New-Folder 'keep colors'
    Invoke-FolderColor @('set', 'teal', $keep) | Out-Null
    $r = Invoke-Script (Join-Path $dest 'uninstall.ps1') @('-KeepColors')
    Check 'uninstall.ps1 -KeepColors succeeds' ($r.Code -eq 0 -and (Test-Uninstalled))
    Check 'the folder keeps its color and its icon' ((Get-IconLine $keep) -match '\\icons\\teal\.ico,0$' -and (Test-Path (Join-Path $dest 'icons\teal.ico')))
    Check 'only the icons and the list of colored folders stay' ((@(Get-ChildItem $dest -Force | ForEach-Object Name | Sort-Object) -join ',') -eq 'colored.txt,icons')
    $r = Invoke-Script (Join-Path $root 'install.ps1') @('-Classic')
    $r = Invoke-Script (Join-Path $dest 'uninstall.ps1')
    Check 'installing again and uninstalling resets it' ($r.Code -eq 0 -and (Test-Reset $keep) -and -not (Test-Path $dest) -and (Test-Uninstalled))
}
finally {
    Remove-TestFolder $work
}
Complete-Tests
