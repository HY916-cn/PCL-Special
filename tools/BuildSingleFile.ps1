#requires -Version 7.0
param([string]$OutputDirectory = 'dist')

$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$output = [IO.Path]::GetFullPath($OutputDirectory, $root)
$artifacts = Join-Path $root 'artifacts/single-file'
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
$report = [ordered]@{ passed = $false; checks = @() }

function Invoke-ExtractOnly([string]$Executable) {
    $process = Start-Process -FilePath $Executable -ArgumentList '--extract-only' -PassThru
    try {
        if (-not $process.WaitForExit(60000)) {
            $process.Kill()
            $process.WaitForExit()
            throw "Single-file extraction exceeded 60 seconds: $Executable"
        }
        return $process.ExitCode
    } finally {
        $process.Dispose()
    }
}

try {
    $framework = Join-Path $env:WINDIR 'Microsoft.NET/Framework64/v4.0.30319'
    $compiler = Join-Path $framework 'csc.exe'
    if (-not (Test-Path -LiteralPath $compiler -PathType Leaf)) {
        throw 'The Windows .NET Framework 64-bit C# compiler is required.'
    }
    $stub = Join-Path $artifacts 'PCLPackageStub.exe'
    $references = @('System.IO.Compression.dll', 'System.IO.Compression.FileSystem.dll',
        'System.Web.Extensions.dll', 'System.Windows.Forms.dll', 'System.Drawing.dll') |
        ForEach-Object { '/reference:' + (Join-Path $framework $_) }
    & $compiler /nologo /target:winexe /platform:x64 /optimize+ /codepage:65001 "/out:$stub" `
        "/win32icon:$root/Plain Craft Launcher 2/Images/icon.ico" `
        "/win32manifest:$root/Plain Craft Launcher 2/app.manifest" `
        $references (Join-Path $PSScriptRoot 'SingleFileLauncher.cs')
    if ($LASTEXITCODE -ne 0) { throw 'Single-file launcher compilation failed.' }
    $report.checks += 'Framework x64 launcher compiled with application icon and manifest'

    $fixture = Join-Path $artifacts ('验收 中文 空格 ' + [Guid]::NewGuid().ToString('N'))
    $source = Join-Path $fixture 'input'
    New-Item -ItemType Directory -Force -Path (Join-Path $source '资料 空格'), (Join-Path $source 'PCL') | Out-Null
    [IO.File]::WriteAllBytes((Join-Path $source 'PCL.exe'), [byte[]](0x4d, 0x5a, 0, 1, 2, 3, 255))
    [IO.File]::WriteAllText((Join-Path $source '资料 空格/说明 文本.txt'), "Unicode 文件与空格路径`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::WriteAllText((Join-Path $source 'PCL/Setup.ini'), "LaunchArgumentTitle:默认标题`r`n", [Text.UTF8Encoding]::new($false))
    $archive = Join-Path $fixture '测试 内容.zip'
    [IO.Compression.ZipFile]::CreateFromDirectory($source, $archive, [IO.Compression.CompressionLevel]::Optimal, $false, [Text.Encoding]::UTF8)
    $wrapper = Join-Path $fixture '测试 单文件.exe'
    $folder = '测试 解压目录'
    & python (Join-Path $PSScriptRoot 'MakeSingleFile.py') --stub $stub --archive $archive --output $wrapper --edition 'PCL验收版' --folder $folder --launcher 'PCL.exe'
    if ($LASTEXITCODE -ne 0) { throw 'Single-file fixture assembly failed.' }
    if ((Invoke-ExtractOnly $wrapper) -ne 0) { throw 'Single-file fixture extraction failed.' }
    $extracted = Join-Path $fixture $folder
    foreach ($relative in @('PCL.exe', '资料 空格/说明 文本.txt', 'PCL/Setup.ini')) {
        $expected = Get-FileHash -LiteralPath (Join-Path $source $relative) -Algorithm SHA256
        $actual = Get-FileHash -LiteralPath (Join-Path $extracted $relative) -Algorithm SHA256
        if ($expected.Hash -ne $actual.Hash) { throw "Extracted fixture bytes differ: $relative" }
    }
    $report.checks += 'Adjacent extraction preserves exact launcher, Unicode asset and initial settings bytes'
    $customSettings = "LaunchArgumentTitle:用户保留的标题`r`nUiLauncherTheme:14`r`n"
    $settingsPath = Join-Path $extracted 'PCL/Setup.ini'
    [IO.File]::WriteAllText($settingsPath, $customSettings, [Text.UTF8Encoding]::new($false))
    $customHash = (Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash
    if ((Invoke-ExtractOnly $wrapper) -ne 0) { throw 'Repeated single-file extraction failed.' }
    if ((Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -ne $customHash) { throw 'Repeated extraction replaced user settings.' }
    $report.checks += 'Repeated extraction preserves modified colon-format PCL/Setup.ini'
    $assetPath = Join-Path $extracted '资料 空格/说明 文本.txt'
    Remove-Item -LiteralPath $assetPath
    if ((Invoke-ExtractOnly $wrapper) -ne 0) { throw 'Missing-file repair failed.' }
    if ((Get-FileHash -LiteralPath $assetPath -Algorithm SHA256).Hash -ne
        (Get-FileHash -LiteralPath (Join-Path $source '资料 空格/说明 文本.txt') -Algorithm SHA256).Hash) {
        throw 'Missing-file repair restored incorrect asset bytes.'
    }
    if ((Get-FileHash -LiteralPath $settingsPath -Algorithm SHA256).Hash -ne $customHash) { throw 'Missing-file repair replaced user settings.' }
    $report.checks += 'Missing asset is repaired while modified user settings remain byte-for-byte intact'

    $original = [IO.File]::ReadAllBytes($wrapper)
    $corruptDirectory = Join-Path $fixture 'corrupt'
    $truncatedDirectory = Join-Path $fixture 'truncated'
    New-Item -ItemType Directory -Path $corruptDirectory, $truncatedDirectory | Out-Null
    $corruptPath = Join-Path $corruptDirectory '损坏 内容.exe'
    $corrupt = [byte[]]$original.Clone()
    $payloadOffset = (Get-Item -LiteralPath $stub).Length + 40
    $corrupt[$payloadOffset] = $corrupt[$payloadOffset] -bxor 1
    [IO.File]::WriteAllBytes($corruptPath, $corrupt)
    $report.corruptExitCode = Invoke-ExtractOnly $corruptPath
    $corruptRoot = Join-Path $corruptDirectory $folder
    $corruptFiles = if (Test-Path -LiteralPath $corruptRoot) { @(Get-ChildItem -LiteralPath $corruptRoot -Recurse -Force -File).Count } else { 0 }
    if ($report.corruptExitCode -eq 0 -or $corruptFiles -ne 0) {
        throw 'Corrupted payload was accepted or extracted files.'
    }
    $truncatedPath = Join-Path $truncatedDirectory '截断 内容.exe'
    $stream = [IO.File]::Create($truncatedPath)
    try { $stream.Write($original, 0, $original.Length - 1) } finally { $stream.Dispose() }
    $report.truncatedExitCode = Invoke-ExtractOnly $truncatedPath
    $truncatedRoot = Join-Path $truncatedDirectory $folder
    $truncatedFiles = if (Test-Path -LiteralPath $truncatedRoot) { @(Get-ChildItem -LiteralPath $truncatedRoot -Recurse -Force -File).Count } else { 0 }
    if ($report.truncatedExitCode -eq 0 -or $truncatedFiles -ne 0) {
        throw 'Truncated payload was accepted or extracted files.'
    }
    $report.checks += 'Corrupt and truncated payloads fail without extraction in non-GUI mode'
    $report.fixtureDirectory = $fixture

    $package = Join-Path $output 'PCL特别版-联机版-2.99.99.exe'
    & python (Join-Path $PSScriptRoot 'MakeSingleFile.py') --stub $stub `
        --archive (Join-Path $output 'PCL特别版-联机版-2.99.99.zip') --output $package `
        --edition 'PCL特别版-联机版' --folder 'PCL联机版-2.99.99' --launcher 'PCL特别版-2.99.99.exe'
    if ($LASTEXITCODE -ne 0) { throw 'PCL特别版-联机版 single-file assembly failed.' }
    $fullCheck = Join-Path $artifacts 'full-check'
    New-Item -ItemType Directory -Force -Path $fullCheck | Out-Null
    $fullWrapper = Join-Path $fullCheck ([IO.Path]::GetFileName($package))
    Copy-Item -LiteralPath $package -Destination $fullWrapper -Force
    if ((Invoke-ExtractOnly $fullWrapper) -ne 0) { throw 'Full multiplayer package extraction failed.' }
    $fullExtracted = Join-Path $fullCheck 'PCL联机版-2.99.99'
    $moduleHash = (Get-FileHash -LiteralPath (Join-Path $fullExtracted 'LinkModules/easytier-windows-x86_64-v2.6.4.zip') -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($moduleHash -ne '27af91e270e554709b048bd32327fefd2dfce5062ae1e8701af7550c6f525f84') {
        throw 'Full multiplayer extraction contains an unexpected EasyTier archive.'
    }
    $launcherName = 'PCL特别版-2.99.99.exe'
    $launcherHash = (Get-FileHash -LiteralPath (Join-Path $fullExtracted $launcherName) -Algorithm SHA256).Hash.ToLowerInvariant()
    if ($launcherHash -ne (Get-FileHash -LiteralPath (Join-Path $output $launcherName) -Algorithm SHA256).Hash.ToLowerInvariant()) {
        throw 'Full multiplayer extraction differs from the built launcher.'
    }
    $report.fullExtraction = [ordered]@{ directory = $fullExtracted; launcherSha256 = $launcherHash; moduleSha256 = $moduleHash }
    $report.checks += 'Full multiplayer wrapper extracts the built launcher and pinned EasyTier archive into artifacts'
    $checksumPath = Join-Path $output 'SHA256SUMS.txt'
    $checksums = Get-ChildItem -LiteralPath $output -File -Recurse | Where-Object FullName -ne $checksumPath |
        Sort-Object FullName | ForEach-Object {
            $relative = $_.FullName.Substring($output.TrimEnd([IO.Path]::DirectorySeparatorChar).Length + 1).Replace('\', '/')
            '{0}  {1}' -f (Get-FileHash -LiteralPath $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $relative
        }
    [IO.File]::WriteAllLines($checksumPath, [string[]]$checksums, [Text.UTF8Encoding]::new($false))
    $report.package = $package
    $report.sha256 = (Get-FileHash -LiteralPath $package -Algorithm SHA256).Hash.ToLowerInvariant()
    $report.passed = $true
    Write-Host "PASS: single-file launcher fixture checks and package assembly: $package"
} catch {
    $report.error = $_.Exception.Message
    throw
} finally {
    $report | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $artifacts 'result.json') -Encoding utf8
}
