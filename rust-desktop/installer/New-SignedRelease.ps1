#Requires -Version 7.2
[CmdletBinding(DefaultParameterSetName = 'Aws')]
param(
    [string] $PublicKeyPath = (Join-Path $PSScriptRoot 'updater.pub'),
    [Parameter(ParameterSetName = 'Aws')]
    [Parameter(Mandatory, ParameterSetName = 'External')]
    [string] $PayloadPath,
    [Parameter(Mandatory, ParameterSetName = 'External')] [string] $SignaturePath,
    [Parameter(Mandatory, ParameterSetName = 'Aws')]
    [ValidatePattern('^arn:aws:secretsmanager:[a-z0-9-]+:[0-9]{12}:secret:[a-zA-Z0-9/_+=.@-]+$')]
    [string] $SigningSecretArn,
    [Parameter(ParameterSetName = 'Aws')] [string] $AWSProfile,
    [Parameter(ParameterSetName = 'Aws')] [ValidatePattern('^[a-zA-Z0-9_-]+$')] [string] $KeyField = 'privateKey',
    [Parameter(ParameterSetName = 'Aws')] [ValidatePattern('^[a-zA-Z0-9_-]+$')] [string] $PasswordField,
    [ValidateSet('installer', 'direct')] [string] $InstallMode = 'installer',
    [string] $OutputDirectory
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
function Invoke-ReleaseSigner($Payload, $Version) {
    $resolver = (Get-Command asm-exec.exe -CommandType Application).Source
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
$inputPayload = if ($PayloadPath) { Get-Item -LiteralPath $PayloadPath }
$inputSignature = if ($SignaturePath) { Get-Item -LiteralPath $SignaturePath }
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
    $metadata = cargo metadata --locked --no-deps --format-version 1 | ConvertFrom-Json
    if ($version -ne ($metadata.packages | Where-Object name -eq 'claude-safe-launcher-rust').version) {
        throw 'Cargo version does not match tauri.conf.json.'
    }
    New-Item -ItemType Directory -Path $stage | Out-Null
    $stem = "Claude-Environment-Checker-v$version-win-x64"
    $updateName = "$stem-update.exe"
    $update = Join-Path $stage $updateName
    if ($inputPayload) {
        if ($inputPayload.Extension -ne '.exe' -or $inputPayload.VersionInfo.ProductName -cne $config.productName -or
            $inputPayload.VersionInfo.ProductVersion -ne $version) {
            throw 'The payload must be the NSIS installer for the current product and version.'
        }
        Copy-Item -LiteralPath $inputPayload.FullName -Destination $update
    } else {
        & "$PSScriptRoot/Build-UpdateBundle.ps1" -OutputDirectory $stage -PublicKeyPath $publicKeyFile | Out-Null
    }
    $signature = "$update.sig"
    if ($inputSignature) {
        Copy-Item -LiteralPath $inputSignature.FullName -Destination $signature
    } else {
        $cli = cargo tauri --version
        if ($cli -notmatch '^tauri-cli ([0-9]+\.[0-9]+\.[0-9]+)$' -or [version]$Matches[1] -lt [version]'2.12.5') {
            throw 'Tauri CLI 2.12.5 or newer is required.'
        }
        Invoke-ReleaseSigner $update $version
    }
    cargo run --locked --no-default-features --features verify-update-package --example verify-update -- $publicKeyFile $update $signature $version
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
