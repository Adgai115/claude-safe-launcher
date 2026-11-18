#Requires -Version 7.2
[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $PublicKeyPath,
    [Parameter(Mandatory)] [ValidatePattern('^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[a-zA-Z0-9/_+=.@-]+$')]
    [string] $SigningSecretArn,
    [string] $AWSProfile,
    [ValidatePattern('^[a-zA-Z0-9_-]+$')] [string] $KeyField = 'privateKey',
    [ValidatePattern('^[a-zA-Z0-9_-]+$')] [string] $PasswordField,
    [ValidateSet('installer', 'direct')] [string] $InstallMode = 'installer',
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
$resolver = (Get-Command asm-exec.exe -CommandType Application).Source

function Invoke-ReleaseSigner($Payload, $Version) {
    $child = [Diagnostics.ProcessStartInfo]::new($resolver)
    $child.UseShellExecute = $false
    foreach ($argument in '--', (Get-Process -Id $PID).Path, '-NoProfile', '-NonInteractive', '-Command',
        '& $env:CSL_RELEASE_CARGO tauri signer sign --app-version $env:CSL_RELEASE_VERSION $env:CSL_RELEASE_PAYLOAD *> $null; exit $LASTEXITCODE') {
        $child.ArgumentList.Add($argument)
    }
    $child.WorkingDirectory = (Get-Location).Path
    $child.Environment['CSL_RELEASE_CARGO'] = (Get-Command cargo.exe -CommandType Application).Source
    $child.Environment['CSL_RELEASE_VERSION'] = $Version
    $child.Environment['CSL_RELEASE_PAYLOAD'] = $Payload
    if ($AWSProfile) { $child.Environment['AWS_PROFILE'] = $AWSProfile }
    $child.Environment['TAURI_SIGNING_PRIVATE_KEY'] = "{{resolve:secretsmanager:${SigningSecretArn}:SecretString:${KeyField}}}"
    [void] $child.Environment.Remove('TAURI_SIGNING_PRIVATE_KEY_PATH')
    $child.Environment['TAURI_SIGNING_PRIVATE_KEY_PASSWORD'] = if ($PasswordField) {
        "{{resolve:secretsmanager:${SigningSecretArn}:SecretString:${PasswordField}}}"
    } else { '' }
    $process = [Diagnostics.Process]::Start($child)
    try {
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw 'Signing failed. Check the AWS session, secret fields and Tauri signing key.' }
    } finally {
        $process.Dispose()
    }
}

$publicKeyFile = (Get-Item -LiteralPath $PublicKeyPath).FullName
$publicKey = (Get-Content -LiteralPath $publicKeyFile -Raw).Trim()
$decodedKey = [Text.Encoding]::ASCII.GetString([Convert]::FromBase64String($publicKey))
if ($decodedKey -notmatch '^untrusted comment: minisign public key') { throw 'Use a Tauri updater public key.' }
$project = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $project 'tauri.conf.json') -Raw | ConvertFrom-Json
$version = $config.version
if ($version -notmatch '^(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)$') { throw 'Expected a stable version in tauri.conf.json.' }
$repository = 'Adgai115/claude-safe-launcher'
if (!$OutputDirectory) { $OutputDirectory = Join-Path $project "target/signed-release/$version" }
$output = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputDirectory)
if (Test-Path -LiteralPath $output) { throw "Choose a new output directory. Already exists: $output" }
$stage = Join-Path $project ('target/signed-stage-' + [guid]::NewGuid().ToString('N'))

Push-Location -LiteralPath $project
try {
    $cli = cargo tauri --version
    if ($cli -notmatch '^tauri-cli ([0-9]+\.[0-9]+\.[0-9]+)$' -or [version]$Matches[1] -lt [version]'2.12.5') {
        throw 'Tauri CLI 2.12.5 or newer is required.'
    }
    $metadata = cargo metadata --locked --no-deps --format-version 1 | ConvertFrom-Json
    if ($version -ne ($metadata.packages | Where-Object name -eq 'claude-safe-launcher-rust').version) {
        throw 'Cargo version does not match tauri.conf.json.'
    }
    New-Item -ItemType Directory -Path $stage | Out-Null
    $stagedPublicKey = Join-Path $stage 'updater.pub'
    Set-Content -LiteralPath $stagedPublicKey -Value $publicKey -Encoding utf8NoBOM
    $override = Join-Path $stage 'tauri.updater.json'
    @{
        bundle = @{ createUpdaterArtifacts = $true }
        plugins = @{ updater = @{
            pubkey = $publicKey
            endpoints = @("https://github.com/$repository/releases/latest/download/latest.json")
            requireSignedVersion = $true
            windows = @{ installMode = 'passive' }
        } }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $override -Encoding utf8NoBOM

    $target = 'x86_64-pc-windows-msvc'
    cargo tauri build --ci --no-sign --target $target --bundles nsis --features signed-updates --config $override -- --locked
    $bundlePath = Join-Path $metadata.target_directory "$target/release/bundle/nsis"
    $payload = @(Get-ChildItem -LiteralPath $bundlePath -Filter '*.exe' | Where-Object {
        $_.VersionInfo.ProductVersion -eq $version -and $_.VersionInfo.ProductName -eq $config.productName
    })
    if ($payload.Count -ne 1) { throw 'Expected a single NSIS bundle for this version.' }

    $stem = "Claude-Environment-Checker-v$version-win-x64"
    $updateName = "$stem-update.exe"
    $update = Join-Path $stage $updateName
    Copy-Item -LiteralPath $payload[0].FullName -Destination $update
    Invoke-ReleaseSigner $update $version
    $signature = "$update.sig"
    cargo run --locked --no-default-features --features verify-update-package --example verify-update -- $stagedPublicKey $update $signature $version
    $setup = & "$PSScriptRoot/Build-Installer.ps1" -Payload $update -OutputPath (Join-Path $stage "$stem-setup.exe")
    powershell.exe -NoProfile -ExecutionPolicy Bypass -File "$PSScriptRoot/Test-Installer.ps1" -Installer $setup.FullName -Version $version

    $manifest = Join-Path $stage 'latest.json'
    @{
        version = $version
        installMode = $InstallMode
        platforms = @{ 'windows-x86_64' = @{
            url = "https://github.com/$repository/releases/download/desktop-v$version/$updateName"
            signature = (Get-Content -LiteralPath $signature -Raw).Trim()
        } }
    } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath $manifest -Encoding utf8NoBOM

    New-Item -ItemType Directory -Path $output | Out-Null
    Copy-Item -LiteralPath $update,$signature,$setup.FullName,$manifest -Destination $output
    Get-ChildItem -LiteralPath $output -File | Get-FileHash -Algorithm SHA256
} finally {
    Pop-Location
}
