# One-line install of the latest release:
#
#   irm https://raw.githubusercontent.com/FewchX/win11-folder-colors/main/get.ps1 | iex
#
# Downloads the release zip into a temporary folder and runs its install.ps1.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue' # the progress bar makes downloads slow in Windows PowerShell
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $url = 'https://github.com/FewchX/win11-folder-colors/releases/latest/download/win11-folder-colors.zip'
    $work = Join-Path ([IO.Path]::GetTempPath()) ('win11-folder-colors-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $work | Out-Null
    try {
        Write-Host "Downloading $url"
        $zip = Join-Path $work 'win11-folder-colors.zip'
        Invoke-WebRequest $url -OutFile $zip -UseBasicParsing
        Expand-Archive $zip $work

        # a separate PowerShell: the default execution policy blocks script files
        powershell.exe -NoProfile -ExecutionPolicy Bypass -File (Join-Path $work 'install.ps1')
        if ($LASTEXITCODE -ne 0) { Write-Host 'Installation failed, see the messages above.' -ForegroundColor Red }
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
