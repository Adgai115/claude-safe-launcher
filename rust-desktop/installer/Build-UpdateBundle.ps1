#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $OutputDirectory,
    [string] $PublicKeyPath = (Join-Path $PSScriptRoot 'updater.pub'),
    [switch] $UseNpx
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$project = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $project 'tauri.conf.json') -Raw | ConvertFrom-Json
$version = $config.version
if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') {
    throw 'Expected a stable version in tauri.conf.json.'
}
$publicKey = (Get-Content -LiteralPath $PublicKeyPath -Raw).Trim()
$decodedKey = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($publicKey))
if ($decodedKey -notmatch '^untrusted comment: minisign public key') { throw 'Use a Tauri updater public key.' }
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
$destination = Join-Path $output "Claude-Environment-Checker-v$version-win-x64-update.exe"
if (Test-Path -LiteralPath $destination) { throw "Bundle already exists: $destination" }
$override = Join-Path ([IO.Path]::GetTempPath()) ("csl-updater-" + [guid]::NewGuid().ToString('N') + ".json")

$cli = 'cargo'
$cliArgs = @('tauri')
if ($UseNpx) {
    $cli = 'npx.cmd'
    $cliArgs = @('--yes', '--package', '@tauri-apps/cli@2.12.5', 'tauri')
}

Push-Location -LiteralPath $project
try {
    $cliVersion = & $cli @cliArgs --version
    if ($cliVersion -notmatch '^tauri-cli ([0-9]+\.[0-9]+\.[0-9]+)$' -or [version]$Matches[1] -lt [version]'2.12.5') {
        throw 'Tauri CLI 2.12.5 or newer is required.'
    }
    $metadata = cargo metadata --locked --no-deps --format-version 1 | ConvertFrom-Json
    if ($version -ne ($metadata.packages | Where-Object name -eq 'claude-safe-launcher-rust').version) {
        throw 'Cargo version does not match tauri.conf.json.'
    }
    @{
        bundle = @{ createUpdaterArtifacts = $true }
        plugins = @{ updater = @{
            pubkey = $publicKey
            endpoints = @('https://github.com/Adgai115/claude-safe-launcher/releases/latest/download/latest.json')
            requireSignedVersion = $true
            windows = @{ installMode = 'passive' }
        } }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $override -Encoding utf8NoBOM

    $target = 'x86_64-pc-windows-msvc'
    & $cli @cliArgs build --ci --no-sign --target $target --bundles nsis --features signed-updates --config $override -- --locked | Out-Host
    $bundlePath = Join-Path $metadata.target_directory "$target/release/bundle/nsis"
    $payload = @(Get-ChildItem -LiteralPath $bundlePath -Filter '*.exe' -File | Where-Object {
        $_.VersionInfo.ProductVersion -eq $version -and $_.VersionInfo.ProductName -ceq $config.productName
    })
    if ($payload.Count -ne 1) { throw 'Expected a single NSIS bundle for this version.' }
    New-Item -ItemType Directory -Path $output -Force | Out-Null
    [IO.File]::Copy($payload[0].FullName, $destination)
    Get-Item -LiteralPath $destination
} finally {
    Pop-Location
    Remove-Item -LiteralPath $override -ErrorAction SilentlyContinue
}
