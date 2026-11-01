param(
    [Parameter(Mandatory = $true)][string]$PortableDirectory,
    [string]$ReportPath = "artifacts/portable-verification.json"
)

$ErrorActionPreference = "Stop"
$PSNativeCommandUseErrorActionPreference = $false
$portable = [IO.Path]::GetFullPath($PortableDirectory)
$reportFile = [IO.Path]::GetFullPath($ReportPath)
$report = [ordered]@{
    passed = $false
    validation = "Inventory integrity, bundled JVM execution, and Minecraft main-class loading (Java --dry-run)"
}
$failure = $null

function Resolve-PortableFile([string]$RelativePath) {
    if ([string]::IsNullOrWhiteSpace($RelativePath) -or [IO.Path]::IsPathRooted($RelativePath)) {
        throw "Expected a relative portable file path: $RelativePath"
    }
    $path = [IO.Path]::GetFullPath((Join-Path $portable $RelativePath))
    $prefix = $portable.TrimEnd([IO.Path]::DirectorySeparatorChar, [IO.Path]::AltDirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
    if (-not $path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
        throw "File path is outside the portable directory: $RelativePath"
    }
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Missing portable file: $RelativePath"
    }
    return $path
}

try {
    $inventoryFile = Resolve-PortableFile "Minecraft-inventory.json"
    $inventory = Get-Content -LiteralPath $inventoryFile -Raw -Encoding UTF8 | ConvertFrom-Json
    if ($inventory.minecraft -ne "26.3" -or $inventory.platform -ne "windows-x64" -or $inventory.java.version -ne "25.0.1") {
        throw "Expected Minecraft 26.3 with Java 25.0.1 for Windows x64."
    }
    $files = @($inventory.files)
    if ($files.Count -eq 0 -or $files.Count -ne $inventory.fileCount) {
        throw "Inventory file count is invalid."
    }
    $verifiedPaths = @{}
    foreach ($entry in $files) {
        $path = Resolve-PortableFile $entry.path
        if ((Get-Item -LiteralPath $path).Length -ne [long]$entry.size) {
            throw "File size does not match the inventory: $($entry.path)"
        }
        if ($entry.sha256 -notmatch '^[a-fA-F0-9]{64}$' -or
            (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash -ne $entry.sha256) {
            throw "File SHA-256 does not match the inventory: $($entry.path)"
        }
        $verifiedPaths[$path] = $true
    }
    $versionFile = Resolve-PortableFile ".minecraft/versions/26.3/26.3.json"
    if (-not $verifiedPaths.ContainsKey($versionFile)) { throw "Version metadata is absent from the inventory." }
    $version = Get-Content -LiteralPath $versionFile -Raw -Encoding UTF8 | ConvertFrom-Json
    $mainClass = [string]$version.mainClass
    if ($version.id -ne "26.3" -or [string]::IsNullOrWhiteSpace($mainClass) -or $mainClass.StartsWith("-")) {
        throw "Minecraft version metadata has an invalid main class or version ID."
    }
    $classpathEntries = @($inventory.classpath)
    if ($classpathEntries.Count -eq 0) { throw "Minecraft classpath is empty." }
    foreach ($entry in $classpathEntries) {
        $path = Resolve-PortableFile $entry
        if (-not $verifiedPaths.ContainsKey($path)) { throw "Classpath file is absent from the inventory: $entry" }
    }
    $javaw = Resolve-PortableFile $inventory.java.executable
    $java = Join-Path (Split-Path $javaw -Parent) "java.exe"
    if (-not $verifiedPaths.ContainsKey($java)) { throw "Bundled java.exe is absent from the inventory." }
    $report.minecraft = $inventory.minecraft
    $report.partial = [bool]$inventory.partial
    $report.assetObjectsIncluded = $inventory.assetObjects
    $report.filesVerified = $files.Count
    $report.classpathEntries = $classpathEntries.Count
    $report.mainClass = $mainClass

    Push-Location $portable
    try {
        $versionOutput = (& $java --version 2>&1 | Out-String).Trim()
        $versionExitCode = $LASTEXITCODE
        $report.javaVersionOutput = $versionOutput
        if ($versionExitCode -ne 0 -or $versionOutput -notmatch '(?m)^(?:openjdk|java)\s+25\.0\.1(?:\s|$)') {
            throw "Bundled Java did not report version 25.0.1 (exit $versionExitCode): $versionOutput"
        }
        $classpath = $classpathEntries -join ";"
        $dryRunOutput = (& $java --dry-run -cp $classpath $mainClass 2>&1 | Out-String).Trim()
        $dryRunExitCode = $LASTEXITCODE
        $report.dryRunExitCode = $dryRunExitCode
        $report.dryRunOutput = $dryRunOutput
        if ($dryRunExitCode -ne 0) {
            throw "Minecraft main-class loading failed (exit $dryRunExitCode): $dryRunOutput"
        }
    } finally {
        Pop-Location
    }
    $report.passed = $true
} catch {
    $failure = $_
    $report.error = $_.Exception.Message
} finally {
    New-Item -ItemType Directory -Force (Split-Path $reportFile -Parent) | Out-Null
    $report | ConvertTo-Json -Depth 4 | Set-Content -LiteralPath $reportFile -Encoding UTF8
}

if ($null -ne $failure) { throw $failure }
Write-Host "PASS: Minecraft 26.3 inventory, Java 25.0.1, and main-class loading verified. Report: $reportFile"
