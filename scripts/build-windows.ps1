$ErrorActionPreference = "Stop"

$root = Split-Path -Parent $PSScriptRoot
$flutterProject = Join-Path $root "mclash"
$serviceProject = Join-Path $root "windows-service"
$packageDir = Join-Path $root "windows-package"
$mihomo = Join-Path $packageDir "mihomo.exe"
$isccCandidates = @(
    (Get-Command ISCC.exe -ErrorAction SilentlyContinue | Select-Object -ExpandProperty Source -First 1),
    (Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"),
    (Join-Path $env:ProgramFiles "Inno Setup 6\ISCC.exe"),
    "D:\Program Files\Inno Setup 6\ISCC.exe"
)
$iscc = $isccCandidates | Where-Object {
    $_ -and (Test-Path -LiteralPath $_ -PathType Leaf)
} | Select-Object -First 1
if (-not $iscc) {
    throw "Inno Setup 6 (ISCC.exe) was not found."
}

$releaseHeaders = @{
    Accept = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2022-11-28"
    "User-Agent" = "Mclash-Windows-Build"
}

if (-not (Test-Path -LiteralPath $mihomo -PathType Leaf) -or
    (Get-Item -LiteralPath $mihomo).Length -eq 0) {
    Write-Host "Downloading the latest official Mihomo Windows amd64 core..."
    $mihomoRelease = Invoke-RestMethod `
        -Headers $releaseHeaders `
        -Uri "https://api.github.com/repos/MetaCubeX/mihomo/releases/latest"
    $mihomoAsset = $mihomoRelease.assets | Where-Object {
        $_.name -match '^mihomo-windows-amd64-compatible-.*\.zip$'
    } | Select-Object -First 1
    if (-not $mihomoAsset -or -not $mihomoAsset.digest -or
        -not $mihomoAsset.digest.StartsWith("sha256:")) {
        throw "The latest Mihomo release has no verifiable Windows amd64-compatible archive."
    }

    $archive = Join-Path $env:TEMP $mihomoAsset.name
    $extractDir = Join-Path $env:TEMP "mclash-mihomo-$([guid]::NewGuid())"
    try {
        Invoke-WebRequest `
            -Headers @{ "User-Agent" = "Mclash-Windows-Build" } `
            -Uri $mihomoAsset.browser_download_url `
            -OutFile $archive
        $expectedHash = $mihomoAsset.digest.Substring(7).ToUpperInvariant()
        $actualHash = (Get-FileHash -LiteralPath $archive -Algorithm SHA256).Hash
        if ($actualHash -ne $expectedHash) {
            throw "Mihomo SHA-256 mismatch: expected=$expectedHash actual=$actualHash"
        }
        Expand-Archive -LiteralPath $archive -DestinationPath $extractDir -Force
        $downloadedCore = Get-ChildItem -LiteralPath $extractDir -Filter "mihomo*.exe" -Recurse |
            Select-Object -First 1
        if (-not $downloadedCore) {
            throw "The Mihomo archive does not contain an executable."
        }
        Copy-Item -LiteralPath $downloadedCore.FullName -Destination $mihomo -Force
    }
    finally {
        Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
        Remove-Item -LiteralPath $extractDir -Recurse -Force -ErrorAction SilentlyContinue
    }
}

Write-Host "Resolving the latest MetaCubeX geodata release..."
$geodataRelease = Invoke-RestMethod `
    -Headers $releaseHeaders `
    -Uri "https://api.github.com/repos/MetaCubeX/meta-rules-dat/releases/latest"
$geodataFiles = @(
    @{ Asset = "geosite.dat"; Installed = "GeoSite.dat" },
    @{ Asset = "geoip.dat"; Installed = "GeoIP.dat" },
    @{ Asset = "country.mmdb"; Installed = "Country.mmdb" }
)

foreach ($entry in $geodataFiles) {
    $asset = $geodataRelease.assets | Where-Object {
        $_.name -ieq $entry.Asset
    } | Select-Object -First 1
    if (-not $asset) {
        throw "The latest MetaCubeX geodata release does not contain $($entry.Asset)."
    }
    if (-not $asset.digest -or -not $asset.digest.StartsWith("sha256:")) {
        throw "The geodata asset $($entry.Asset) has no SHA-256 digest."
    }

    $expectedHash = $asset.digest.Substring(7).ToUpperInvariant()
    $destination = Join-Path $packageDir $entry.Asset
    $validCachedFile = (Test-Path -LiteralPath $destination -PathType Leaf) -and `
        ((Get-FileHash -LiteralPath $destination -Algorithm SHA256).Hash -eq $expectedHash)
    if (-not $validCachedFile) {
        $temporary = "$destination.download"
        try {
            Invoke-WebRequest `
                -Headers @{ "User-Agent" = "Mclash-Windows-Build" } `
                -Uri $asset.browser_download_url `
                -OutFile $temporary
            $actualHash = (Get-FileHash -LiteralPath $temporary -Algorithm SHA256).Hash
            if ($actualHash -ne $expectedHash) {
                throw "$($entry.Asset) SHA-256 mismatch: expected=$expectedHash actual=$actualHash"
            }
            Move-Item -LiteralPath $temporary -Destination $destination -Force
        }
        finally {
            if (Test-Path -LiteralPath $temporary) {
                Remove-Item -LiteralPath $temporary -Force
            }
        }
    }
    Write-Host "Geodata ready: $($entry.Installed)"
}

Push-Location $flutterProject
try {
    flutter pub get
    dart format lib
    flutter analyze
    flutter build windows --release
}
finally {
    Pop-Location
}

Push-Location $serviceProject
try {
    $env:GOOS = "windows"
    $env:GOARCH = "amd64"
    $env:CGO_ENABLED = "0"
    go mod tidy
    gofmt -w .
    go build -trimpath -ldflags="-s -w" -o "$packageDir\mihomoService.exe" .
}
finally {
    Pop-Location
}

$releaseDir = Join-Path $flutterProject "build\windows\x64\runner\Release"
Remove-Item -LiteralPath (Join-Path $releaseDir "MclashService.exe") -Force -ErrorAction SilentlyContinue
Copy-Item -LiteralPath (Join-Path $packageDir "mihomoService.exe") -Destination $releaseDir -Force
Copy-Item -LiteralPath $mihomo -Destination $releaseDir -Force

& $iscc (Join-Path $root "installer\Mclash.iss")
if ($LASTEXITCODE -ne 0) {
    throw "Inno Setup failed with exit code $LASTEXITCODE."
}
$installer = Join-Path $root "installer\Output\Mclash-Windows-Setup-1.0.0.exe"
Write-Host "Windows installer: $installer"
