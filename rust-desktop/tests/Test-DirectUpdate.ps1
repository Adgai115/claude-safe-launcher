#Requires -Version 7.2
[CmdletBinding()]
param()

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true
if ($env:GITHUB_ACTIONS -ne 'true' -or $env:RUNNER_ENVIRONMENT -ne 'github-hosted') {
    throw 'Run the upgrade smoke test on a disposable GitHub-hosted Windows runner.'
}

$workspace = Split-Path -Parent $PSScriptRoot
$work = Join-Path $env:RUNNER_TEMP 'direct-update-smoke'
New-Item -Path $work -ItemType Directory | Out-Null
$testKey = Join-Path $work 'fixture.key'
$overlay = Join-Path $work 'updater.json'
$cli = @('--yes', '--package', '@tauri-apps/cli@2.12.5', 'tauri')
$env:RUSTUP_TOOLCHAIN = 'stable'
Push-Location -LiteralPath $workspace

$candidateConfig = Get-Content -LiteralPath tauri.conf.json -Raw | ConvertFrom-Json
$candidateVersion = [version]$candidateConfig.version
$candidateTag = "desktop-v$candidateVersion"
$candidateIsReleased = (git tag --list $candidateTag) -eq $candidateTag
if ($candidateIsReleased) {
    $baseTag = $candidateTag
    $baseVersion = $candidateVersion
    $patchVersion = [version]::new($candidateVersion.Major, $candidateVersion.Minor, $candidateVersion.Build + 1)
} else {
    if ($candidateVersion.Build -lt 1) {
        throw "Cannot derive the previous patch release for candidate $candidateVersion."
    }
    $baseVersion = [version]::new($candidateVersion.Major, $candidateVersion.Minor, $candidateVersion.Build - 1)
    $baseTag = "desktop-v$baseVersion"
    $patchVersion = $candidateVersion
    if ((git tag --list $baseTag) -ne $baseTag) {
        throw "Previous patch release tag $baseTag was not found."
    }
}
Write-Host "Testing direct upgrade $baseVersion -> $patchVersion from $baseTag."

function Build-TestBundle([version] $Version) {
    npx.cmd @cli build --ci --no-sign --bundles nsis --features signed-updates --config $overlay -- --locked | Out-Host
    $bundle = @(Get-ChildItem target/release/bundle/nsis -Filter '*.exe' -File |
        Where-Object { $_.VersionInfo.ProductVersion -eq $Version.ToString() })
    if ($bundle.Count -ne 1) { throw "Expected one test installer for $Version." }
    $file = Join-Path $work "fixture-$Version.exe"
    Copy-Item -LiteralPath $bundle[0].FullName -Destination $file
    return $file
}

try {
    # Disposable test key. The production signing account is not used by this job.
    npx.cmd @cli signer generate --ci --write-keys $testKey --password 'local-test' *> $null
    @{
        bundle = @{ createUpdaterArtifacts = $true }
        plugins = @{ updater = @{
            pubkey = (Get-Content -LiteralPath "$testKey.pub" -Raw).Trim()
            endpoints = @('https://localhost:42723/latest.json')
            requireSignedVersion = $true
            windows = @{ installMode = 'passive' }
        } }
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $overlay -Encoding utf8NoBOM

    git restore --source=$baseTag -- src ui tauri.conf.json Cargo.toml Cargo.lock
    $baseInstaller = Build-TestBundle $baseVersion
    git restore --source=$env:GITHUB_SHA -- src ui tauri.conf.json Cargo.toml Cargo.lock
    $config = Get-Content -LiteralPath tauri.conf.json -Raw | ConvertFrom-Json
    $sourceVersion = [version]$config.version
    $metadata = cargo metadata --locked --no-deps --format-version 1 | ConvertFrom-Json
    $cargoVersion = [version]($metadata.packages | Where-Object name -eq 'claude-safe-launcher-rust').version
    if ($cargoVersion -ne $sourceVersion) {
        throw "Cargo version $cargoVersion does not match Tauri version $sourceVersion."
    }
    if ($sourceVersion -ne $patchVersion) {
        if ($sourceVersion -ne $baseVersion) {
            throw "Expected candidate source version $baseVersion or $patchVersion, got $sourceVersion."
        }
        $config.version = $patchVersion.ToString()
        $config | ConvertTo-Json -Depth 20 | Set-Content -LiteralPath tauri.conf.json -Encoding utf8NoBOM
        foreach ($file in 'Cargo.toml', 'Cargo.lock') {
            $pattern = '(?m)(^name = "claude-safe-launcher-rust"\r?\nversion = ")' + [regex]::Escape($sourceVersion) + '"'
            $original = Get-Content -LiteralPath $file -Raw
            $patched = [regex]::Replace($original, $pattern, {
                param($match)
                $match.Groups[1].Value + $patchVersion + '"'
            })
            if ($patched -ceq $original) { throw "Failed to set fixture version in $file." }
            Set-Content -LiteralPath $file -Value $patched -NoNewline -Encoding utf8NoBOM
        }
    }
    $patchInstaller = Build-TestBundle $patchVersion
    $env:TAURI_SIGNING_PRIVATE_KEY_PATH = $testKey
    $env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD = 'local-test'
    npx.cmd @cli signer sign --app-version "$patchVersion" $patchInstaller *> $null
    Remove-Item Env:TAURI_SIGNING_PRIVATE_KEY_PATH, Env:TAURI_SIGNING_PRIVATE_KEY_PASSWORD -ErrorAction SilentlyContinue
    Remove-Item -LiteralPath $testKey

    $cert = New-SelfSignedCertificate -DnsName localhost -CertStoreLocation Cert:\CurrentUser\My
    $certificate = Join-Path $work 'localhost.cer'
    $pfx = Join-Path $work 'localhost.pfx'
    Export-Certificate -Cert $cert -FilePath $certificate | Out-Null
    Export-PfxCertificate -Cert $cert -FilePath $pfx -CryptoAlgorithmOption AES256_SHA256 -Password (ConvertTo-SecureString 'local-test' -AsPlainText -Force) | Out-Null
    certutil.exe -f -addstore Root $certificate | Out-Host

    $installPath = Join-Path $work 'Custom Install Path'
    $installed = Start-Process -FilePath $baseInstaller -ArgumentList "/S /D=$installPath" -PassThru -Wait -WindowStyle Hidden
    if ($installed.ExitCode -ne 0) { throw "Base installation failed with exit $($installed.ExitCode)." }
    $exe = Join-Path $installPath 'claude-safe-launcher-rust.exe'
    if ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -ne "$baseVersion") {
        throw "Expected the baseline app in its custom installation directory."
    }
    $debugPolicy = 'HKCU:\Software\Policies\Microsoft\Edge\WebView2\AdditionalBrowserArguments'
    New-Item -Path $debugPolicy -Force | Out-Null
    New-ItemProperty -Path $debugPolicy -Name 'claude-safe-launcher-rust.exe' -Value '--remote-debugging-port=42724' -PropertyType String | Out-Null

    $dataPath = Join-Path $env:LOCALAPPDATA 'io.github.adgai115.claude-safe-launcher-rust'
    New-Item -Path $dataPath -ItemType Directory -Force | Out-Null
    $mockClaude = Join-Path $work 'Claude.exe'
    cargo build --locked --no-default-features --example claude-window-fixture | Out-Host
    $targetDirectory = (cargo metadata --locked --no-deps --format-version 1 | ConvertFrom-Json).target_directory
    $fixture = Join-Path $targetDirectory 'debug/examples/claude-window-fixture.exe'
    if (!(Test-Path -LiteralPath $fixture)) { throw 'Claude window fixture was not built.' }
    Copy-Item -LiteralPath $fixture -Destination $mockClaude
    $baseline = Join-Path $dataPath 'preflight.json'
    @{
        claudeGroup = 'Upgrade smoke baseline'
        expectedNode = 'Fixture node'
        expectedIp = '192.0.2.40'
        expectedLoc = 'US'
        timezone = (Get-TimeZone).Id
        autoRepair = $false
        claudeExe = $mockClaude
    } | ConvertTo-Json | Set-Content -LiteralPath $baseline -Encoding utf8NoBOM

    npm.cmd install --no-save --no-package-lock --prefix $work playwright-core@1.65.1
    $env:NODE_PATH = Join-Path $work 'node_modules'
    node "$PSScriptRoot/upgrade-smoke.cjs" $pfx $exe $baseline $mockClaude $patchInstaller "$baseVersion" "$patchVersion"
    if ((Get-Item -LiteralPath $exe).VersionInfo.ProductVersion -ne "$patchVersion") {
        throw "The updated app was not installed in the custom installation directory."
    }
} finally {
    Pop-Location
}
