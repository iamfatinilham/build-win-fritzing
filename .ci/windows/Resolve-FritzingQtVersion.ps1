[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectFile,
    [Parameter(Mandatory)]
    [ValidateSet('windows', 'windows_arm64')]
    [string]$QtHost,
    [Parameter(Mandatory)]
    [string]$Architecture,
    # Fritzing's phoenix.pro uses serialport, SVG/SVGWidgets, and Core5Compat.
    # Qt's repository ships SVG in the base desktop package (and therefore it
    # does not appear in `aqt list-qt --modules`). Only ask aqt to resolve the
    # two add-on modules. The workflow still verifies Qt6Svg.dll after install.
    [string[]]$RequiredModules = @('qtserialport', 'qt5compat')
)

$ErrorActionPreference = 'Stop'

function Invoke-Aqt {
    param([string[]]$Arguments, [string]$Description)

    $output = & python -m aqt @Arguments
    if ($null -ne $LASTEXITCODE -and $LASTEXITCODE -ne 0) {
        throw "$Description failed with exit code $LASTEXITCODE."
    }
    return @($output)
}

$contractReader = Join-Path $PSScriptRoot 'Get-FritzingBuildContract.ps1'
$contract = & $contractReader -ProjectFile $ProjectFile

# aqt understands a SimpleSpec but install-qt-action v4 later tries to parse
# that same string as a strict SemVer. Resolve it ourselves and hand the
# installer only an exact version.
$available = Invoke-Aqt @('list-qt', $QtHost, 'desktop', '--spec', $contract.QtRange) "List Qt versions for $QtHost"
$versions = @($available | ForEach-Object { $_ -split '\s+' } | Where-Object { $_ -match '^\d+\.\d+\.\d+$' } | Sort-Object { [version]$_ } -Descending -Unique)
if ($versions.Count -eq 0) {
    throw "aqt found no Qt versions matching Fritzing's declared range $($contract.QtRange) for $QtHost."
}

foreach ($version in $versions) {
    $architectures = @(Invoke-Aqt @('list-qt', $QtHost, 'desktop', '--arch', $version) "List architectures for Qt $version" | ForEach-Object { $_ -split '\s+' })
    if ($architectures -notcontains $Architecture) { continue }

    $modules = @(Invoke-Aqt @('list-qt', $QtHost, 'desktop', '--modules', $version, $Architecture) "List modules for Qt $version" | ForEach-Object { $_ -split '\s+' })
    $missingModule = @($RequiredModules | Where-Object { $modules -notcontains $_ })
    if ($missingModule.Count -eq 0) {
        [pscustomobject]@{
            QtVersion = $version
            QtRange = $contract.QtRange
            QtHost = $QtHost
            Architecture = $Architecture
        }
        return
    }
}

throw "No Qt kit for $QtHost/$Architecture within $($contract.QtRange) contains: $($RequiredModules -join ', ')."
