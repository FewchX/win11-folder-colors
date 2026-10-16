# Helpers shared by the test scripts, which dot-source this file.

$script:failures = 0

function Check($name, [bool]$ok) {
    if ($ok) { Write-Host "  ok    $name" }
    else { Write-Host "  FAIL  $name" -ForegroundColor Red; $script:failures++ }
}

# A new empty folder under %TEMP%, by its long name: %TEMP% can be a short
# 8.3 path (C:\Users\RUNNER~1 on CI), while Windows reports selected and moved
# folders under their long paths.
function New-TestFolder($prefix) {
    $path = Join-Path ([IO.Path]::GetTempPath()) ($prefix + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $path | Out-Null
    if (-not ('FolderColorsTest.Native' -as [type])) {
        Add-Type -Namespace FolderColorsTest -Name Native -MemberDefinition '
            [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
            public static extern uint GetLongPathNameW(string shortPath, System.Text.StringBuilder longPath, uint size);'
    }
    $long = New-Object Text.StringBuilder 32768
    if ([FolderColorsTest.Native]::GetLongPathNameW($path, $long, $long.Capacity) -gt 0) { return $long.ToString() }
    return $path
}

# folders the tests made read-only can't be deleted until that bit is cleared
function Remove-TestFolder($path) {
    if ($path -and (Test-Path -LiteralPath $path)) {
        Get-ChildItem -LiteralPath $path -Recurse -Force -Directory | ForEach-Object { $_.Attributes = 'Directory' }
        Remove-Item -LiteralPath $path -Recurse -Force
    }
}

# the .NET Framework 4 C# compiler, as install.ps1 finds it
function Find-Csc {
    return @('Framework64', 'Framework') | ForEach-Object { Join-Path $env:WINDIR "Microsoft.NET\$_\v4.0.30319\csc.exe" } |
        Where-Object { Test-Path $_ } | Select-Object -First 1
}

# the CPU File Explorer runs on, as install.ps1 finds it
function Get-NativeArch {
    $cpu = (Get-ItemProperty 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
    if ($cpu -eq 'ARM64') { return 'arm64' }
    return 'x64'
}

function Complete-Tests {
    Write-Host ''
    if ($script:failures) {
        Write-Host "$($script:failures) check(s) failed." -ForegroundColor Red
        exit 1
    }
    Write-Host 'All checks passed.' -ForegroundColor Green
}
