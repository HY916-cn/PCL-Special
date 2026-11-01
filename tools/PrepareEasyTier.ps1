#requires -Version 7.0
param([string]$OutputDirectory = 'dist/LinkModules')

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Split-Path $PSScriptRoot -Parent
$output = [IO.Path]::GetFullPath($OutputDirectory, $root)
New-Item -ItemType Directory -Force -Path $output | Out-Null

function Get-VerifiedArchive([string]$Name, [string]$Url, [string]$Sha256) {
    $destination = Join-Path $output $Name
    if ((Test-Path -LiteralPath $destination -PathType Leaf) -and
        (Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $Sha256) {
        Write-Host "Verified existing $Name"
        return
    }
    $temporary = "$destination.$([Guid]::NewGuid().ToString('N')).part"
    try {
        for ($attempt = 1; $attempt -le 3; $attempt++) {
            try {
                Invoke-WebRequest -Uri $Url -OutFile $temporary -TimeoutSec 120
                if ((Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash -ne $Sha256) {
                    throw "SHA-256 verification failed for $Name."
                }
                [IO.File]::Move($temporary, $destination, $true)
                Write-Host "Downloaded and verified $Name"
                return
            } catch {
                if ($attempt -eq 3) { throw }
                Start-Sleep -Seconds 2
            }
        }
    } finally {
        if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force }
    }
}

Get-VerifiedArchive -Name 'easytier-windows-x86_64-v2.6.4.zip' `
    -Url 'https://github.com/EasyTier/EasyTier/releases/download/v2.6.4/easytier-windows-x86_64-v2.6.4.zip' `
    -Sha256 '27af91e270e554709b048bd32327fefd2dfce5062ae1e8701af7550c6f525f84'
Get-VerifiedArchive -Name 'EasyTier-8428a89d2dabc94c97d370ec607c6ca142473626-source.zip' `
    -Url 'https://codeload.github.com/EasyTier/EasyTier/zip/8428a89d2dabc94c97d370ec607c6ca142473626' `
    -Sha256 'f1dd7cdad133c521715fa836f8af1b1851f0cdab9360cb897f2e346c36068075'

foreach ($name in @('LGPL-3.0.txt', 'GPL-3.0.txt', 'NOTICE.txt')) {
    Copy-Item -LiteralPath (Join-Path $root "licenses/EasyTier/$name") -Destination (Join-Path $output "EasyTier-$name") -Force
}
Write-Host "EasyTier v2.6.4 archives, corresponding source and license notices are ready in $output"
