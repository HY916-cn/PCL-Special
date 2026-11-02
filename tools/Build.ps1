param([string]$OutputDirectory = "dist")
$ErrorActionPreference = "Stop"
$root = Split-Path $PSScriptRoot -Parent
Push-Location $root
try {
    $secretPath = Join-Path $root "Plain Craft Launcher 2/Modules/ModSecret.vb"
    $originalSecret = [IO.File]::ReadAllBytes($secretPath)
    try {
        if (-not [string]::IsNullOrWhiteSpace($env:PCL_CURSEFORGE_API_KEY)) {
            $key = $env:PCL_CURSEFORGE_API_KEY.Trim()
            if ($key -match '["\r\n]') { throw "Invalid CurseForge API key format." }
            $marker = 'Public Const DefaultCurseForgeAPIKey As String = ""'
            $secretSource = [IO.File]::ReadAllText($secretPath)
            if (-not $secretSource.Contains($marker)) { throw "CurseForge build key marker was not found." }
            $secretSource = $secretSource.Replace($marker, 'Public Const DefaultCurseForgeAPIKey As String = "' + $key + '"')
            [IO.File]::WriteAllText($secretPath, $secretSource, [Text.UTF8Encoding]::new($false))
        }
        dotnet restore PCLCS/PCLCS.csproj
        if ($LASTEXITCODE -ne 0) { throw "NuGet restore failed." }
        msbuild "Plain Craft Launcher 2/Plain Craft Launcher 2.vbproj" /m /p:Configuration=Release /verbosity:minimal
        if ($LASTEXITCODE -ne 0) { throw "MSBuild failed." }
    } finally {
        # Restore the source before creating the source archive, including on build failure.
        [IO.File]::WriteAllBytes($secretPath, $originalSecret)
        $key = $null
        $secretSource = $null
    }

    $output = [IO.Path]::GetFullPath((Join-Path $root $OutputDirectory))
    New-Item -ItemType Directory -Force $output | Out-Null
    $name = "PCL特别版-2.99.99"
    & (Join-Path $PSScriptRoot 'PrepareEasyTier.ps1') -OutputDirectory (Join-Path $output 'LinkModules')
    Copy-Item "Plain Craft Launcher 2/obj/Release/Plain Craft Launcher 2.exe" "$output/$name.exe"
    Copy-Item "Plain Craft Launcher 2/App.config" "$output/$name.exe.config"
    Copy-Item "$output/$name.exe" "$output/PCL特别版-精简版-2.99.99.exe"
    Copy-Item README.md "$output/使用说明.md"
    Copy-Item LICENCE "$output/LICENCE"
    $hasGit = Test-Path (Join-Path $root ".git")
    $revision = if ($hasGit) { git rev-parse HEAD } else { ((Select-String -Path "$root/SOURCE.txt" -Pattern "^Build commit: ").Line -replace "^Build commit: ", "") }
    $coreRevision = "4c60c2962c3b50bc3fe96ed5dd9259b980173580"
    @"
PCL特别版 2.99.99
制作开发者：Haoyu Huang
Build commit: $revision
Upstream: Meloong-Git/PCL 93ede5d9e638c99fcec853a9ba1eecd91ceee7f5
MeloongCore: $coreRevision
"@ | Set-Content "$output/SOURCE.txt" -Encoding utf8
    $files = @("$output/$name.exe", "$output/$name.exe.config", "$output/使用说明.md", "$output/LICENCE", "$output/SOURCE.txt", "$output/LinkModules")
    Compress-Archive -LiteralPath "$output/PCL特别版-精简版-2.99.99.exe" -DestinationPath "$output/PCL特别版-精简版-2.99.99.zip" -Force
    Compress-Archive -Path $files -DestinationPath "$output/PCL特别版-联机版-2.99.99.zip" -Force

    $source = Join-Path $root "artifacts/source"
    New-Item -ItemType Directory -Force $source | Out-Null
    if ($hasGit) {
        $tracked = git -c core.quotepath=false ls-files --recurse-submodules
        if ($LASTEXITCODE -ne 0) { throw "Source inventory failed." }
    } else {
        $tracked = Get-ChildItem $root -Recurse -Force -File | ForEach-Object { $_.FullName.Substring($root.Length + 1) } |
            Where-Object { $_ -notmatch '(^|[\\/])(\.git|bin|obj|dist|artifacts)[\\/]' }
    }
    foreach ($file in $tracked) {
        $target = Join-Path $source $file
        New-Item -ItemType Directory -Force (Split-Path $target -Parent) | Out-Null
        Copy-Item -LiteralPath (Join-Path $root $file) -Destination $target
    }
    Copy-Item "$output/SOURCE.txt" "$source/SOURCE.txt"
    Compress-Archive -Path "$source/*" -DestinationPath "$output/$name-Source.zip" -Force
    Get-ChildItem $output -File -Recurse | Where-Object Name -ne "SHA256SUMS.txt" |
        ForEach-Object { "{0}  {1}" -f (Get-FileHash $_.FullName -Algorithm SHA256).Hash.ToLowerInvariant(), $_.FullName.Substring($output.Length + 1).Replace('\', '/') } |
        Set-Content "$output/SHA256SUMS.txt" -Encoding utf8
} finally {
    Pop-Location
}
