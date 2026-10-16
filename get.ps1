# One-line install of the latest release:
#
#   irm https://raw.githubusercontent.com/FewchX/win11-folder-colors/main/get.ps1 | iex
#
# Downloads the release zip into a temporary folder, checks it against the
# SHA-256 GitHub lists for that file, and runs its install.ps1.

& {
    $ErrorActionPreference = 'Stop'
    $ProgressPreference = 'SilentlyContinue' # the progress bar makes downloads slow in Windows PowerShell
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12

    $release = Invoke-RestMethod 'https://api.github.com/repos/FewchX/win11-folder-colors/releases/latest' -UseBasicParsing
    $asset = @($release.assets | Where-Object { $_.name -eq 'win11-folder-colors.zip' })[0]
    if (-not $asset -or "$($asset.digest)" -notmatch '^sha256:([0-9a-f]{64})$') { throw "Release $($release.tag_name) has no checksum for win11-folder-colors.zip." }
    $expected = $Matches[1]

    $work = Join-Path ([IO.Path]::GetTempPath()) ('win11-folder-colors-' + [guid]::NewGuid().ToString('N').Substring(0, 8))
    New-Item -ItemType Directory $work | Out-Null
    try {
        Write-Host "Downloading Folder Colors $($release.tag_name)"
        $zip = Join-Path $work 'win11-folder-colors.zip'
        Invoke-WebRequest $asset.browser_download_url -OutFile $zip -UseBasicParsing
        $actual = (Get-FileHash $zip -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($actual -ne $expected) { throw "The download doesn't match its checksum (expected $expected, got $actual). Nothing was installed." }
        $files = Join-Path $work 'files'
        Expand-Archive $zip $files

        # a separate Windows PowerShell: the default execution policy blocks script files
        & (Join-Path $env:WINDIR 'System32\WindowsPowerShell\v1.0\powershell.exe') -NoProfile -ExecutionPolicy Bypass -File (Join-Path $files 'install.ps1')
        if ($LASTEXITCODE -ne 0) { Write-Host 'Installation failed, see the messages above.' -ForegroundColor Red }
    }
    finally {
        Remove-Item $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
