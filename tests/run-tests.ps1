# Tests FolderColor.exe end to end on throwaway folders under %TEMP%:
# builds it and the icons into a temporary install folder, colors and resets
# folders there and checks desktop.ini, attributes, colored.txt and git.
# Never touches folders outside that temporary folder. Run by CI on every push.
#
#   powershell -NoProfile -ExecutionPolicy Bypass -File tests\run-tests.ps1

$ErrorActionPreference = 'Stop'

$root = Split-Path $PSScriptRoot
$work = Join-Path ([IO.Path]::GetTempPath()) ('folder-colors-test-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
$app = Join-Path $work 'app'
$exe = Join-Path $app 'FolderColor.exe'
$data = Join-Path $work 'data'
$failures = 0

function Check($name, [bool]$ok) {
    if ($ok) { Write-Host "  ok    $name" }
    else { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:failures++ }
}

# runs FolderColor.exe; stderr goes to a file, so errors are reported there instead of a dialog
function Invoke-FolderColor([string[]]$arguments) {
    $err = Join-Path $work 'stderr.txt'
    $quoted = $arguments | ForEach-Object { if ($_ -match '\s|^$') { "`"$_`"" } else { $_ } }
    $p = Start-Process $exe -ArgumentList $quoted -Wait -PassThru -NoNewWindow -RedirectStandardError $err
    $message = if (Test-Path $err) { [IO.File]::ReadAllText($err).Trim() } else { '' }
    return [pscustomobject]@{ Code = $p.ExitCode; Error = $message }
}

function New-Folder($name) {
    $path = Join-Path $data $name
    New-Item -ItemType Directory -Force $path | Out-Null
    return $path
}

function Read-Ini($folder) {
    $ini = Join-Path $folder 'desktop.ini'
    if (Test-Path -LiteralPath $ini) { return [IO.File]::ReadAllText($ini) }
    return $null
}

function Test-ReadOnly($folder) { return [bool]((Get-Item -LiteralPath $folder -Force).Attributes -band [IO.FileAttributes]::ReadOnly) }

function Get-Colored {
    $list = Join-Path $app 'colored.txt'
    if (Test-Path $list) { return @(Get-Content $list -Encoding UTF8) }
    return @()
}

# folders made read-only by the tests can't be deleted by Remove-Item without -Force
function Remove-Work {
    if (Test-Path $work) {
        Get-ChildItem $work -Recurse -Force -Directory | ForEach-Object { $_.Attributes = 'Directory' }
        Remove-Item $work -Recurse -Force
    }
}

try {
    New-Item -ItemType Directory -Force $app, $data | Out-Null

    Write-Host 'Build'
    $csc = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319\csc.exe'
    & $csc /nologo /target:winexe /optimize+ /codepage:65001 /reference:System.Drawing.dll "/out:$exe" `
        (Join-Path $root 'src\FolderColor.cs') (Join-Path $root 'src\IconBuilder.cs')
    Check 'FolderColor.exe compiles' ($LASTEXITCODE -eq 0)
    if ($LASTEXITCODE -ne 0) { throw 'Compilation failed.' }

    $colors = Get-Content (Join-Path $root 'colors.json') -Raw -Encoding UTF8 | ConvertFrom-Json
    $specs = $colors | ForEach-Object { '{0}={1}' -f $_.id, ($_.ramp -join ',') }
    $r = Invoke-FolderColor (@('build-icons', (Join-Path $app 'icons'), (Join-Path $app 'Assets')) + $specs)
    Check "build-icons succeeds $($r.Error)" ($r.Code -eq 0)
    foreach ($c in $colors) {
        $bytes = [IO.File]::ReadAllBytes((Join-Path $app "icons\$($c.id).ico"))
        Check "$($c.id).ico has 8 frames" ([BitConverter]::ToUInt16($bytes, 4) -eq 8)
    }
    Check 'menu.ico and the package logos exist' ((Test-Path (Join-Path $app 'icons\menu.ico')) -and
        @(Get-ChildItem (Join-Path $app 'Assets') -Filter *.png).Count -eq 3)
    $r = Invoke-FolderColor @('build-icons', (Join-Path $app 'icons'), (Join-Path $app 'Assets'), 'menu=#000000,#111111,#222222')
    Check 'build-icons refuses the id "menu"' ($r.Code -ne 0)
    $r = Invoke-FolderColor @('build-icons', (Join-Path $app 'icons'), (Join-Path $app 'Assets'), '..\x=#000000,#111111,#222222')
    Check 'build-icons refuses an id with a path in it' ($r.Code -ne 0 -and -not (Test-Path (Join-Path $app 'x.ico')))

    Write-Host 'Set and reset'
    $plain = New-Folder 'plain folder'
    $r = Invoke-FolderColor @('set', 'red', $plain)
    $ini = Read-Ini $plain
    Check 'set exits 0' ($r.Code -eq 0)
    Check 'desktop.ini points at red.ico' ($ini -match '(?m)^IconResource=.*\\icons\\red\.ico,0\r?$')
    $local = [Environment]::GetFolderPath('LocalApplicationData')
    if ($app.StartsWith($local + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Check 'desktop.ini uses %LOCALAPPDATA%, not the user name' ($ini -match '(?m)^IconResource=%LOCALAPPDATA%\\' -and $ini -notmatch [regex]::Escape($local))
    }
    $attrs = (Get-Item -LiteralPath (Join-Path $plain 'desktop.ini') -Force).Attributes
    Check 'desktop.ini is hidden and system' (($attrs -band 'Hidden') -and ($attrs -band 'System'))
    Check 'folder has the read-only bit' (Test-ReadOnly $plain)
    Check 'colored.txt lists the folder' ((Get-Colored) -contains $plain)

    $r = Invoke-FolderColor @('set', 'blue', $plain)
    Check 'recolor replaces the line' (([regex]::Matches((Read-Ini $plain), 'IconResource=')).Count -eq 1 -and (Read-Ini $plain) -match 'blue\.ico')
    Check 'recolor keeps colored.txt free of duplicates' (@(Get-Colored | Where-Object { $_ -eq $plain }).Count -eq 1)

    $r = Invoke-FolderColor @('reset', $plain)
    Check 'reset exits 0' ($r.Code -eq 0)
    Check 'reset deletes desktop.ini' ($null -eq (Read-Ini $plain))
    Check 'reset clears the read-only bit' (-not (Test-ReadOnly $plain))
    Check 'reset takes the folder off colored.txt' (-not ((Get-Colored) -contains $plain))

    Write-Host 'A folder with its own desktop.ini'
    $special = New-Folder 'special'
    $own = "[.ShellClassInfo]`r`nLocalizedResourceName=@%SystemRoot%\system32\shell32.dll,-21770`r`nIconResource=%SystemRoot%\system32\imageres.dll,-112`r`n[ViewState]`r`nMode=`r`nVid=`r`nFolderType=Documents`r`n"
    [IO.File]::WriteAllText((Join-Path $special 'desktop.ini'), $own, [Text.Encoding]::Unicode)
    Invoke-FolderColor @('set', 'green', $special) | Out-Null
    $ini = Read-Ini $special
    Check 'own icon kept for reset' ($ini -match 'FolderColorsOriginal=IconResource=%SystemRoot%\\system32\\imageres\.dll,-112')
    Check 'other settings kept' ($ini -match 'LocalizedResourceName=' -and $ini -match '\[ViewState\]' -and $ini -match 'FolderType=Documents')
    Invoke-FolderColor @('set', 'pink', $special) | Out-Null
    Check 'a second color keeps the first original' (([regex]::Matches((Read-Ini $special), 'FolderColorsOriginal=')).Count -eq 1 -and (Read-Ini $special) -match 'FolderColorsOriginal=IconResource=%SystemRoot%')
    Invoke-FolderColor @('reset', $special) | Out-Null
    $ini = Read-Ini $special
    Check 'reset brings back the own icon' ($ini -match '(?m)^IconResource=%SystemRoot%\\system32\\imageres\.dll,-112\r?$')
    Check 'reset leaves no trace' ($ini -notmatch 'FolderColors' -and $ini -notmatch '\\icons\\')
    Check 'reset keeps the other settings' ($ini -match 'LocalizedResourceName=' -and $ini -match 'FolderType=Documents')

    Write-Host 'Several folders, odd paths'
    $many = @('a', 'b c', 'd [e]', "f'g") | ForEach-Object { New-Folder "many\$_" }
    $r = Invoke-FolderColor (@('set', 'teal') + $many)
    Check 'one call colors every folder' ($r.Code -eq 0 -and @($many | Where-Object { (Read-Ini $_) -match 'teal\.ico' }).Count -eq 4)
    $r = Invoke-FolderColor (@('reset') + $many)
    Check 'one call resets every folder' ($r.Code -eq 0 -and @($many | Where-Object { Read-Ini $_ }).Count -eq 0)
    # the classic menu's "%1" for a path ending in a backslash leaves a stray quote
    $p = Start-Process $exe -ArgumentList "set red `"$plain\`"" -Wait -PassThru -NoNewWindow -RedirectStandardError (Join-Path $work 'stderr.txt')
    Check 'a trailing backslash is handled' ($p.ExitCode -eq 0 -and (Read-Ini $plain) -match 'red\.ico')
    Invoke-FolderColor @('reset', $plain) | Out-Null

    Write-Host 'Bad input'
    $r = Invoke-FolderColor @('set', '..\..\evil', $plain)
    Check 'a color id with a path is refused' ($r.Code -eq 2 -and $null -eq (Read-Ini $plain))
    $r = Invoke-FolderColor @('set', 'nosuchcolor', $plain)
    Check 'an unknown color is reported' ($r.Code -eq 1 -and $r.Error -match 'No icon' -and $null -eq (Read-Ini $plain))
    $r = Invoke-FolderColor @('set', 'red', (Join-Path $data 'missing'))
    Check 'a missing folder is reported' ($r.Code -eq 1 -and $r.Error -match 'Folder not found')
    $drive = [IO.Path]::GetPathRoot($data)
    $r = Invoke-FolderColor @('set', 'red', $drive)
    Check 'a drive root is refused' ($r.Code -eq 1 -and $r.Error -match 'whole drive' -and -not (Test-Path -LiteralPath (Join-Path $drive 'desktop.ini')))
    $r = Invoke-FolderColor @('set', 'red', (Join-Path $data 'missing'), $plain)
    Check 'one bad folder does not stop the others' ($r.Code -eq 1 -and (Read-Ini $plain) -match 'red\.ico')
    Invoke-FolderColor @('reset', $plain) | Out-Null
    $r = Invoke-FolderColor @('set', 'red')
    Check 'no folder is a usage error' ($r.Code -eq 2)

    Write-Host 'Links'
    $linked = New-Folder 'linked'
    $target = Join-Path $data 'precious.txt'
    [IO.File]::WriteAllText($target, 'keep me')
    # mklink, unlike New-Item in Windows PowerShell, can use Developer Mode instead of admin rights
    cmd /c mklink "$(Join-Path $linked 'desktop.ini')" "$target" 2>&1 | Out-Null
    if (-not (Test-Path -LiteralPath (Join-Path $linked 'desktop.ini'))) {
        Write-Host '  skip  symbolic links need Developer Mode or admin rights'
    }
    else {
        $r = Invoke-FolderColor @('set', 'red', $linked)
        Check 'a desktop.ini link is refused' ($r.Code -eq 1 -and $r.Error -match 'link')
        Check 'the file it points to is untouched' ([IO.File]::ReadAllText($target) -eq 'keep me' -and
            -not ((Get-Item $target -Force).Attributes -band 'Hidden'))
        $r = Invoke-FolderColor @('reset', $linked)
        Check 'reset refuses it too' ($r.Code -eq 1 -and [IO.File]::ReadAllText($target) -eq 'keep me')
    }

    Write-Host 'Folders this program never colored'
    $foreign = New-Folder 'customized in Properties'
    $foreignIni = "[.ShellClassInfo]`r`nIconResource=C:\Windows\System32\shell32.dll,4`r`n"
    [IO.File]::WriteAllText((Join-Path $foreign 'desktop.ini'), $foreignIni, [Text.Encoding]::Unicode)
    (Get-Item -LiteralPath $foreign).Attributes = 'Directory, ReadOnly'
    $r = Invoke-FolderColor @('reset', $foreign)
    Check 'reset leaves a foreign icon alone' ($r.Code -eq 0 -and (Read-Ini $foreign) -eq $foreignIni -and (Test-ReadOnly $foreign))
    $empty = New-Folder 'never colored'
    $r = Invoke-FolderColor @('reset', $empty)
    Check 'reset on a plain folder is a no-op' ($r.Code -eq 0 -and $null -eq (Read-Ini $empty) -and -not (Test-ReadOnly $empty))

    Write-Host 'refresh (upgrade from 1.0)'
    $old = New-Folder 'colored by 1.0'
    $oldIni = "[.ShellClassInfo]`r`nIconResource=$app\icons\orange.ico,0`r`nInfoTip=kept`r`n"
    [IO.File]::WriteAllText((Join-Path $old 'desktop.ini'), $oldIni, [Text.Encoding]::Unicode)
    [IO.File]::WriteAllLines((Join-Path $app 'colored.txt'), [string[]]@($old, (Join-Path $data 'gone')))
    $r = Invoke-FolderColor @('refresh')
    $ini = Read-Ini $old
    Check 'refresh exits 0 despite a missing folder' ($r.Code -eq 0)
    Check 'refresh rewrites the icon line' ($ini -match '(?m)^IconResource=.*\\icons\\orange\.ico,0\r?$' -and $ini -match 'InfoTip=kept')
    if ($app.StartsWith($local + '\', [StringComparison]::OrdinalIgnoreCase)) {
        Check 'refresh drops the user name from the path' ($ini -match '%LOCALAPPDATA%' -and $ini -notmatch [regex]::Escape($local))
    }
    Invoke-FolderColor @('reset', $old) | Out-Null
    Check 'a refreshed folder resets cleanly' ((Read-Ini $old) -notmatch 'IconResource' -and (Read-Ini $old) -match 'InfoTip=kept')
    [IO.File]::WriteAllText((Join-Path $app 'colored.txt'), '')

    Write-Host 'git'
    $git = Get-Command git -ErrorAction SilentlyContinue
    if ($git) {
        $repo = New-Folder 'repo'
        & $git.Source init -q $repo
        $exclude = Join-Path $repo '.git\info\exclude'
        $before = [IO.File]::ReadAllText($exclude)
        $inner = New-Folder 'repo\inner'
        Invoke-FolderColor @('set', 'red', $inner) | Out-Null
        Check 'nothing in .git is touched' ([IO.File]::ReadAllText($exclude) -eq $before)
        Invoke-FolderColor @('reset', $inner) | Out-Null
    }
    else {
        Write-Host '  skip  git is not installed'
    }

    Write-Host 'Parallel runs'
    $parallel = 1..6 | ForEach-Object { New-Folder "parallel\$_" }
    $procs = $parallel | ForEach-Object { Start-Process $exe -ArgumentList @('set', 'purple', "`"$_`"") -PassThru -NoNewWindow -RedirectStandardError (Join-Path $work "stderr-$(Split-Path $_ -Leaf).txt") }
    $procs | ForEach-Object { $_.WaitForExit() }
    $listed = Get-Colored
    Check 'no run loses another one''s entry in colored.txt' (@($parallel | Where-Object { $listed -contains $_ }).Count -eq 6)
    Check 'every folder is colored' (@($parallel | Where-Object { (Read-Ini $_) -match 'purple\.ico' }).Count -eq 6)
    Invoke-FolderColor (@('reset') + $parallel) | Out-Null
    Check 'colored.txt is empty after resetting everything' (@(Get-Colored | Where-Object { $_.Trim() }).Count -eq 0)
}
finally {
    Remove-Work
}

Write-Host ''
if ($failures) {
    Write-Host "$failures check(s) failed." -ForegroundColor Red
    exit 1
}
Write-Host 'All checks passed.' -ForegroundColor Green
