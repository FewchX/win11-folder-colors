# Tests FolderColorMenu.dll, the Windows 11 menu handler, without installing
# anything: tests\bin\<arch>\menu-harness.exe loads the DLL from a temporary
# app folder and calls it the way File Explorer does - which selections get
# the menu, what it shows, and that its items color and reset the folders.
# Never touches folders outside that temporary folder. Needs build.ps1 -Tests
# first; run by CI on x64 and ARM64.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-menu-tests.ps1 [-Arch x64|arm64]

param([ValidateSet('x64', 'arm64')][string]$Arch)

$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot 'common.ps1')
if (-not $Arch) { $Arch = Get-NativeArch }

$root = Split-Path $PSScriptRoot
$harness = Join-Path $PSScriptRoot "bin\$Arch\menu-harness.exe"
$builtDll = Join-Path $root "bin\$Arch\FolderColorMenu.dll"
foreach ($file in $harness, $builtDll) { if (-not (Test-Path $file)) { throw "$file is missing: run build.ps1 -Tests first." } }

$work = New-TestFolder 'folder-colors-menu-test-'
$app = Join-Path $work 'app'
$exe = Join-Path $app 'FolderColor.exe'
$dll = Join-Path $app 'FolderColorMenu.dll'
$data = Join-Path $work 'data'
# not only English: menu.txt is UTF-8
$title = 'Folder color ' + (-join [char[]](0x0426, 0x0432, 0x0435, 0x0442))

function New-Folder($name) {
    $path = Join-Path $data $name
    New-Item -ItemType Directory -Force $path | Out-Null
    return $path
}

function Get-IconLine($folder) {
    $ini = Join-Path $folder 'desktop.ini'
    if (Test-Path -LiteralPath $ini) { return [IO.File]::ReadAllLines($ini) | Where-Object { $_ -like 'IconResource=*' } }
    return $null
}

function Get-Colored {
    $list = Join-Path $app 'colored.txt'
    if (Test-Path $list) { return @(Get-Content $list -Encoding UTF8 | Where-Object { $_.Trim() } | ForEach-Object { ($_ -split "`t")[0] }) }
    return @()
}

# menu-harness.exe on the DLL in $app; its output lines are UTF-8
function Invoke-Menu([string[]]$arguments) {
    $out = Join-Path $work 'harness.txt'
    $quoted = (@($dll) + $arguments) | ForEach-Object { if ($_ -match '\s|^$') { "`"$_`"" } else { $_ } }
    $p = Start-Process $harness -ArgumentList $quoted -PassThru -NoNewWindow -RedirectStandardOutput $out
    $null = $p.Handle # keeps the exit code readable after the process ends
    if (-not $p.WaitForExit(60000)) { $p.Kill(); throw "menu-harness $arguments hangs." }
    return [pscustomobject]@{ Code = $p.ExitCode; Lines = @([IO.File]::ReadAllLines($out)) }
}

# A click starts FolderColor.exe and returns at once, like in File Explorer:
# wait for it. One still running after two minutes is stuck in an error
# message box (stderr isn't redirected here) - stopped, and reported.
function Wait-FolderColor {
    $running = @(Get-Process FolderColor -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe })
    $running | Wait-Process -Timeout 120 -ErrorAction SilentlyContinue
    $stuck = @($running | Where-Object { -not $_.HasExited })
    $stuck | Stop-Process -Force
    return $stuck.Count -eq 0
}

try {
    New-Item -ItemType Directory -Force $app, $data | Out-Null

    Write-Host "Setup ($Arch)"
    & (Find-Csc) /nologo /target:winexe /optimize+ /codepage:65001 /reference:System.Drawing.dll "/out:$exe" `
        (Join-Path $root 'src\FolderColor.cs') (Join-Path $root 'src\IconBuilder.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Compiling FolderColor.exe failed.' }
    $colors = Get-Content (Join-Path $root 'colors.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $colors = @($colors) # Windows PowerShell's ConvertFrom-Json returns the array as one object
    $specs = $colors | ForEach-Object { '{0}={1}' -f $_.id, ($_.ramp -join ',') }
    $p = Start-Process $exe -Wait -PassThru -NoNewWindow -RedirectStandardError (Join-Path $work 'stderr.txt') -ArgumentList (
        @('build-icons', "`"$(Join-Path $app 'icons')`"", "`"$(Join-Path $app 'Assets')`"") + $specs)
    if ($p.ExitCode -ne 0) { throw "Building the icons failed: $([IO.File]::ReadAllText((Join-Path $work 'stderr.txt')))" }
    Copy-Item $builtDll $dll
    # in the format install.ps1 writes
    $menu = @($title) + ($colors | ForEach-Object { "$($_.id)`t$($_.label)" }) + @("reset`tReset to default")
    [IO.File]::WriteAllText((Join-Path $app 'menu.txt'), ($menu -join "`r`n") + "`r`n", (New-Object Text.UTF8Encoding $false))
    Check "the harness and the DLL load ($Arch)" ((Invoke-Menu @('state', $data)).Code -eq 0)

    Write-Host 'What the menu shows'
    $folder = New-Folder 'one'
    $r = Invoke-Menu @('describe', $folder)
    $rows = @($r.Lines | ForEach-Object { , ($_ -split "`t") })
    Check 'describe succeeds' ($r.Code -eq 0 -and $rows.Count -gt 0 -and $rows[0][0] -eq 'root')
    Check 'the title comes from menu.txt, in UTF-8' ($rows[0][1] -eq $title)
    Check 'the menu icon is menu.ico' ($rows[0][2] -eq (Join-Path $app 'icons\menu.ico'))
    Check 'the menu has a submenu' (([Convert]::ToUInt32($rows[0][3], 16) -band 0x1) -ne 0) # ECF_HASSUBCOMMANDS
    $items = @($rows | Where-Object { $_[0] -eq 'item' })
    Check 'one item per color, then reset' ($items.Count -eq $colors.Count + 1)
    $i = 0
    $right = 0
    foreach ($c in $colors) {
        $icon = Join-Path $app "icons\$($c.id).ico"
        if ($items[$i][1] -eq $c.label -and $items[$i][2] -eq $icon -and (Test-Path $icon)) { $right++ }
        $i++
    }
    Check 'each color item has its label and its icon' ($right -eq $colors.Count)
    $reset = $items[$items.Count - 1]
    Check 'reset comes last, after a separator, with the stock icon' ($reset[1] -eq 'Reset to default' -and
        ([Convert]::ToUInt32($reset[3], 16) -band 0x20) -ne 0 -and $reset[2] -match 'imageres\.dll,-3$') # ECF_SEPARATORBEFORE

    Write-Host 'Where the menu shows'
    $other = New-Folder 'two'
    $named = New-Folder ('with spaces ' + (-join [char[]](0x041F, 0x0430, 0x043F, 0x043A, 0x0430)))
    $file = Join-Path $data 'file.txt'
    [IO.File]::WriteAllText($file, 'text')
    $zip = Join-Path $data 'archive.zip'
    Compress-Archive -LiteralPath $file -DestinationPath $zip
    Check 'a folder gets it' (@((Invoke-Menu @('state', $folder)).Lines) -contains 'ENABLED')
    Check 'several folders get it' (@((Invoke-Menu @('state', $folder, $other, $named)).Lines) -contains 'ENABLED')
    Check 'a file does not' (@((Invoke-Menu @('state', $file)).Lines) -contains 'HIDDEN')
    Check 'a zip file does not' (@((Invoke-Menu @('state', $zip)).Lines) -contains 'HIDDEN')
    Check 'folders mixed with a file do not' (@((Invoke-Menu @('state', $folder, $file)).Lines) -contains 'HIDDEN')
    Check 'This PC does not' (@((Invoke-Menu @('state', '::{20D04FE0-3AEA-1069-A2D8-08002B30309D}')).Lines) -contains 'HIDDEN')

    Write-Host 'Clicking an item'
    $r = Invoke-Menu @('invoke', 'Blue', $folder, $named)
    $finished = Wait-FolderColor
    Check 'the click starts FolderColor.exe' ($r.Code -eq 0 -and $r.Lines -contains 'invoked 00000000')
    Check 'FolderColor.exe finishes without an error' $finished
    Check 'every selected folder turns blue' (@($folder, $named | Where-Object { (Get-IconLine $_) -match '\\icons\\blue\.ico,0$' }).Count -eq 2)
    Check 'colored.txt lists them' ((Get-Colored) -contains $folder -and (Get-Colored) -contains $named)
    $r = Invoke-Menu @('invoke', 'Reset to default', $folder, $named)
    $finished = Wait-FolderColor
    Check 'reset brings back the stock icon' ($r.Code -eq 0 -and $finished -and $null -eq (Get-IconLine $folder) -and $null -eq (Get-IconLine $named))
    Check 'an item that is not there is reported' ((Invoke-Menu @('invoke', 'No such color', $folder)).Code -eq 1)

    Write-Host 'A selection longer than one command line'
    $many = 1..300 | ForEach-Object { New-Folder ('many\{0:D3} {1}' -f $_, ('x' * 96)) }
    $listFile = Join-Path $work 'many.txt'
    [IO.File]::WriteAllLines($listFile, [string[]]$many, (New-Object Text.UTF8Encoding $false))
    Check 'the paths add up to more than 32767 characters' ((($many | Measure-Object -Property Length -Sum).Sum + 3 * $many.Count) -gt 32767)
    $r = Invoke-Menu @('invoke', 'Green', "@$listFile")
    $finished = Wait-FolderColor
    Check 'the click succeeds' ($r.Code -eq 0 -and $r.Lines -contains 'invoked 00000000' -and $finished)
    Check 'all 300 folders turn green' (@($many | Where-Object { (Get-IconLine $_) -match '\\icons\\green\.ico,0$' }).Count -eq 300)
    Check 'colored.txt lists all 300' (@(Get-Colored | Where-Object { $_ -like (Join-Path $data 'many\*') }).Count -eq 300)
    $r = Invoke-Menu @('invoke', 'Reset to default', "@$listFile")
    $finished = Wait-FolderColor
    Check 'one reset takes all 300 back' ($r.Code -eq 0 -and $finished -and @($many | Where-Object { Get-IconLine $_ }).Count -eq 0)
    Check 'colored.txt is empty again' ((Get-Colored).Count -eq 0)
}
finally {
    Get-Process FolderColor -ErrorAction SilentlyContinue | Where-Object { $_.Path -eq $exe } | Stop-Process -Force
    Remove-TestFolder $work
}
Complete-Tests
