# Builds bin\FolderColorMenu.dll, the Windows 11 context menu handler.
# Only needed when installing from a git clone: release zips already contain it.
#
# Needs Python with the ziglang package (pip install ziglang==0.16.0), which
# brings a complete C++ toolchain for Windows - no Visual Studio required.
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
    throw "Python package 'ziglang' not found. Install it with: $Python -m pip install ziglang==0.16.0"
}

& $Python -m ziglang c++ -shared -O2 -target x86_64-windows-gnu -municode -w `
    -o (Join-Path $out 'FolderColorMenu.dll') `
    (Join-Path $root 'src\FolderColorMenu.cpp') (Join-Path $root 'src\FolderColorMenu.def') `
    -lole32 -lshlwapi -lshell32
$code = $LASTEXITCODE
$ErrorActionPreference = 'Stop'
if ($code -ne 0) { throw 'Building FolderColorMenu.dll failed.' }

# zig also leaves an import library and debug info next to the DLL
Remove-Item (Join-Path $out 'FolderColorMenu.lib'), (Join-Path $out 'FolderColorMenu.pdb') -ErrorAction SilentlyContinue
Write-Host "Built $(Join-Path $out 'FolderColorMenu.dll')"
