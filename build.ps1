# Builds FolderColorMenu.dll, the Windows 11 context menu handler, for x64 and
# ARM64 PCs: bin\x64\FolderColorMenu.dll and bin\arm64\FolderColorMenu.dll.
# Release zips already contain both. install.ps1 runs this when the DLL is
# missing and the toolchain below is available, and downloads the released DLL
# otherwise.
#
# Needs Python with the ziglang package, which brings a complete C++ toolchain
# for Windows - no Visual Studio required, and it builds for both kinds of PC
# on either. Install the exact pinned wheel with
#   python -m pip install --require-hashes -r requirements-build.txt
#
#   -Python <exe>    the Python to use (default: python on PATH)
#   -Arch <list>     x64, arm64 or both (default: both)
#   -Tests           also build tests\bin\<arch>\menu-harness.exe, which the
#                    tests use to drive the DLL the way File Explorer does

param([string]$Python = 'python', [ValidateSet('x64', 'arm64')][string[]]$Arch = @('x64', 'arm64'), [switch]$Tests)

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$targets = @{ x64 = @{ Triple = 'x86_64-windows-gnu'; Machine = 0x8664 }; arm64 = @{ Triple = 'aarch64-windows-gnu'; Machine = 0xAA64 } }

# native programs' stderr turns into errors under 'Stop'; only exit codes matter here
$ErrorActionPreference = 'Continue'
& $Python -c 'import ziglang' 2>$null
$found = $LASTEXITCODE -eq 0
$ErrorActionPreference = 'Stop'
if (-not $found) {
    throw "Python package 'ziglang' not found. Install it with: $Python -m pip install --require-hashes -r $(Join-Path $root 'requirements-build.txt')"
}

# The PE header names the CPU a binary is for: a mix-up would only show up as
# a menu that silently never appears.
function Test-Machine($file, $machine) {
    $bytes = [IO.File]::ReadAllBytes($file)
    $pe = [BitConverter]::ToInt32($bytes, 0x3C)
    return [BitConverter]::ToUInt16($bytes, $pe + 4) -eq $machine
}

function Invoke-Zig($what, $target, $output, [string[]]$arguments) {
    New-Item -ItemType Directory -Force (Split-Path $output) | Out-Null
    $ErrorActionPreference = 'Continue'
    # -Os -s: optimized for size, no symbols (about 180 KB instead of 440 KB).
    # The first build for a CPU also compiles zig's C++ library, with pages of
    # warnings about its code: shown only when the build fails.
    $log = & $Python -m ziglang c++ -Os -s -target $target.Triple -municode -w -o $output @arguments 2>&1
    $code = $LASTEXITCODE
    $ErrorActionPreference = 'Stop'
    if ($code -ne 0) {
        $log | ForEach-Object { Write-Host "$_" }
        throw "Building $what failed."
    }
    if (-not (Test-Machine $output $target.Machine)) { throw "$output is not a $($target.Triple) binary." }
    # zig also leaves an import library and debug info next to it
    Remove-Item ([IO.Path]::ChangeExtension($output, 'lib')), ([IO.Path]::ChangeExtension($output, 'pdb')) -ErrorAction SilentlyContinue
    Write-Host "Built $output"
}

foreach ($a in $Arch) {
    $target = $targets[$a]
    Invoke-Zig "FolderColorMenu.dll ($a)" $target (Join-Path $root "bin\$a\FolderColorMenu.dll") @(
        '-shared', (Join-Path $root 'src\FolderColorMenu.cpp'), (Join-Path $root 'src\FolderColorMenu.def'),
        '-lole32', '-lshlwapi', '-lshell32')
    if ($Tests) {
        Invoke-Zig "menu-harness.exe ($a)" $target (Join-Path $root "tests\bin\$a\menu-harness.exe") @(
            (Join-Path $root 'tests\menu-harness.cpp'), '-lole32', '-lshell32')
    }
}
