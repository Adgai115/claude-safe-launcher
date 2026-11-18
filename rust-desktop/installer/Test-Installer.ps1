[CmdletBinding()]
param(
    [Parameter(Mandatory)] [string] $Installer,
    [Parameter(Mandatory)] [string] $Version
)

$ErrorActionPreference = 'Stop'
$setup = Get-Item -LiteralPath $Installer
if ($setup.VersionInfo.ProductVersion -ne $Version) {
    throw "Installer version differs from $Version."
}

Add-Type -AssemblyName PresentationFramework
$assembly = [Reflection.Assembly]::LoadFile($setup.FullName)
foreach ($name in 'Setup.View', 'Setup.License.En', 'Setup.License.Zh', 'Setup.Payload') {
    $resource = $assembly.GetManifestResourceStream($name)
    if ($null -eq $resource) { throw "Missing setup resource $name." }
    try {
        if ($resource.Length -eq 0) { throw "Empty setup resource $name." }
    } finally {
        $resource.Dispose()
    }
}

$type = $assembly.GetType('Setup', $true)
$normalize = $type.GetMethod('NormalizeInstallPath', [Reflection.BindingFlags]'Static, NonPublic')
$custom = 'D:\Claude 自定义目录\with spaces'
if ($normalize.Invoke($null, [object[]]@($custom, $true)) -cne $custom) {
    throw 'Custom install path was changed.'
}
if ($normalize.Invoke($null, [object[]]@('D:\', $true)) -cne 'D:\Claude Environment Checker') {
    throw 'A drive root must use the English install folder.'
}
if ($null -ne $normalize.Invoke($null, [object[]]@('D:\', $false))) {
    throw 'A drive root must not be treated as an existing installation.'
}
Get-FileHash -LiteralPath $setup.FullName -Algorithm SHA256
