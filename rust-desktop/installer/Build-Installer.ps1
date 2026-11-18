[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string] $Payload,

    [Parameter(Mandatory)]
    [string] $OutputPath
)

$ErrorActionPreference = 'Stop'
$desktop = Split-Path -Parent $PSScriptRoot
$config = Get-Content -LiteralPath (Join-Path $desktop 'tauri.conf.json') -Raw -Encoding UTF8 | ConvertFrom-Json
$version = [version]$config.version
$source = Get-Item -LiteralPath $Payload
if ($source.Extension -ne '.exe' -or $source.VersionInfo.ProductName -cne $config.productName -or
    ([version]$source.VersionInfo.ProductVersion).ToString(3) -ne $version.ToString(3)) {
    throw 'The payload must be the NSIS installer for the current product and version.'
}

$framework = Join-Path $env:WINDIR 'Microsoft.NET\Framework64\v4.0.30319'
$compiler = Join-Path $framework 'csc.exe'
$icon = Join-Path $desktop 'icons\icon.ico'
$destination = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if ([string]::Equals($destination, $source.FullName, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The output path must be different from the embedded NSIS installer.'
}
New-Item -ItemType Directory -Path (Split-Path -Parent $destination) -Force | Out-Null

$metadata = Join-Path ([IO.Path]::GetTempPath()) ("csl-setup-" + [guid]::NewGuid().ToString('N') + ".cs")
try {
    @"
using System.Reflection;
[assembly: AssemblyTitle("$($config.productName) 安装程序")]
[assembly: AssemblyProduct("$($config.productName)")]
[assembly: AssemblyVersion("$($version.ToString(3)).0")]
[assembly: AssemblyFileVersion("$($version.ToString(3)).0")]
[assembly: AssemblyInformationalVersion("$($version.ToString(3))")]
"@ | Set-Content -LiteralPath $metadata -Encoding UTF8

    $options = @(
        '/nologo', '/target:winexe', '/platform:x64', '/optimize+', '/codepage:65001',
        "/out:$destination", "/win32manifest:$(Join-Path $PSScriptRoot 'Setup.manifest')",
        "/win32icon:$icon", "/reference:$(Join-Path $framework 'System.Xaml.dll')",
        "/reference:$(Join-Path $framework 'WPF\WindowsBase.dll')",
        "/reference:$(Join-Path $framework 'WPF\PresentationCore.dll')",
        "/reference:$(Join-Path $framework 'WPF\PresentationFramework.dll')",
        "/resource:$(Join-Path $PSScriptRoot 'Setup.xaml'),Setup.View",
        "/resource:$icon,Setup.Icon",
        "/resource:$(Join-Path $desktop '..\LICENSE'),Setup.License.En",
        "/resource:$(Join-Path $PSScriptRoot 'License.zh-Hans.txt'),Setup.License.Zh",
        "/resource:$($source.FullName),Setup.Payload",
        (Join-Path $PSScriptRoot 'Setup.cs'), $metadata
    )
    & $compiler @options
    if ($LASTEXITCODE -ne 0) { throw "The installer build failed with exit code $LASTEXITCODE." }
    Get-Item -LiteralPath $destination
}
finally {
    Remove-Item -LiteralPath $metadata -ErrorAction SilentlyContinue
}
