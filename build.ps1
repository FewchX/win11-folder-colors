# Builds bin\FolderColorMenu.dll, the Windows 11 context menu handler.
# Release zips already contain it. install.ps1 runs this when the DLL is missing
# and the toolchain below is available, and downloads the released DLL otherwise.
#
# Needs Python with the ziglang package, which brings a complete C++ toolchain
# for Windows - no Visual Studio required. Install the exact pinned wheel with
#   python -m pip install --require-hashes -r requirements-build.txt
#
#   -Python <exe>   the Python to use (default: python on PATH)

param([string]$Python = 'python')

$ErrorActionPreference = 'Stop'

$root = $PSScriptRoot
$out = Join-Path $root 'bin'
New-Item -ItemType Directory -Force $out | Out-Null

# native programs' stderr turns into errors under 'Stop'; only exit codes matter here
$ErrorActionPreference = 'Continue'
& $Python -c 'import ziglang' 2>$null
if ($LASTEXITCODE -ne 0) {
    throw "Python package 'ziglang' not found. Install it with: $Python -m pip install --require-hashes -r $(Join-Path $root 'requirements-build.txt')"
}

# -Os -s: optimized for size, no symbols (about 180 KB instead of 440 KB)
& $Python -m ziglang c++ -shared -Os -s -target x86_64-windows-gnu -municode -w `
    -o (Join-Path $out 'FolderColorMenu.dll') `
    (Join-Path $root 'src\FolderColorMenu.cpp') (Join-Path $root 'src\FolderColorMenu.def') `
    -lole32 -lshlwapi -lshell32
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) { throw 'Building FolderColorMenu.dll failed.' }

# zig also leaves an import library and debug info next to the DLL
Remove-Item (Join-Path $out 'FolderColorMenu.lib'), (Join-Path $out 'FolderColorMenu.pdb') -ErrorAction SilentlyContinue
Write-Host "Built $(Join-Path $out 'FolderColorMenu.dll')"
