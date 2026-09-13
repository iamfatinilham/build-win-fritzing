[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [string]$ProjectFile
)

$ErrorActionPreference = 'Stop'

function Get-RequiredTextFile {
    param([string]$Path)

    if (-not (Test-Path -LiteralPath $Path -PathType Leaf)) {
        throw "Fritzing build contract file is missing: $Path"
    }
    return Get-Content -LiteralPath $Path -Raw
}

function Get-RequiredMatch {
    param(
        [string]$Content,
        [string]$Pattern,
        [string]$Description
    )

    $match = [regex]::Match($Content, $Pattern, [System.Text.RegularExpressions.RegexOptions]::Multiline)
    if (-not $match.Success -or [string]::IsNullOrWhiteSpace($match.Groups[1].Value)) {
        throw "Could not read $Description from the Fritzing source. The upstream build contract has changed."
    }
    return $match.Groups[1].Value.Trim()
}

function Assert-Version {
    param([string]$Value, [string]$Description)

    if ($Value -notmatch '^\d+(?:\.\d+){0,2}$') {
        throw "The $Description value '$Value' is not a supported numeric version."
    }
}

$resolvedProject = (Resolve-Path -LiteralPath $ProjectFile).Path
$projectDirectory = Split-Path -Parent $resolvedProject
$project = Get-RequiredTextFile $resolvedProject

$qtMinimum = Get-RequiredMatch $project '^\s*QT_LEAST\s*=\s*([0-9]+(?:\.[0-9]+){1,2})\s*$' 'QT_LEAST'
$qtMaximum = Get-RequiredMatch $project '^\s*QT_MOST\s*=\s*([0-9]+(?:\.[0-9]+){1,2})\s*$' 'QT_MOST'
Assert-Version $qtMinimum 'QT_LEAST'
Assert-Version $qtMaximum 'QT_MOST'
if ([version]$qtMinimum -gt [version]$qtMaximum) {
    throw "Fritzing's Qt range is invalid: $qtMinimum is greater than $qtMaximum."
}

$libgit = Get-RequiredTextFile (Join-Path $projectDirectory 'pri\libgit2detect.pri')
$quazip = Get-RequiredTextFile (Join-Path $projectDirectory 'pri\quazipdetect.pri')
$clipper = Get-RequiredTextFile (Join-Path $projectDirectory 'pri\clipper1detect.pri')
$boost = Get-RequiredTextFile (Join-Path $projectDirectory 'pri\boostdetect.pri')
$svgpp = Get-RequiredTextFile (Join-Path $projectDirectory 'pri\svgppdetect.pri')
$ngspice = Get-RequiredTextFile (Join-Path $projectDirectory 'pri\spicedetect.pri')

$libgit2Version = Get-RequiredMatch $libgit '^\s*LIBGIT_VERSION\s*=\s*([0-9]+(?:\.[0-9]+){1,2})\s*$' 'libgit2 version'
$quazipVersion = Get-RequiredMatch $quazip '^\s*QUAZIP_VERSION\s*=\s*([0-9]+(?:\.[0-9]+){1,2})\s*$' 'QuaZip version'
$clipperVersion = Get-RequiredMatch $clipper 'Clipper1-([0-9]+(?:\.[0-9]+){1,2})' 'Clipper version'
$boostCandidates = Get-RequiredMatch $boost '^\s*BOOSTS\s*=\s*([0-9]+(?:[ \t]+[0-9]+)*)\s*$' 'Boost minor version'
$boostMinor = ($boostCandidates -split '\s+' | Select-Object -Last 1)
$svgppVersion = Get-RequiredMatch $svgpp 'svgpp-([0-9]+(?:\.[0-9]+){1,2})' 'SVG++ version'
$ngspiceVersion = Get-RequiredMatch $ngspice 'ngspice-([0-9]+(?:\.[0-9]+){0,2})' 'ngspice version'

foreach ($entry in @(
    @{ Value = $libgit2Version; Name = 'libgit2 version' },
    @{ Value = $quazipVersion; Name = 'QuaZip version' },
    @{ Value = $clipperVersion; Name = 'Clipper version' },
    @{ Value = $svgppVersion; Name = 'SVG++ version' },
    @{ Value = $ngspiceVersion; Name = 'ngspice version' }
)) {
    Assert-Version $entry.Value $entry.Name
}

[pscustomobject]@{
    QtMinimum       = $qtMinimum
    QtMaximum       = $qtMaximum
    QtRange         = ">=$qtMinimum,<=$qtMaximum"
    Libgit2Version  = $libgit2Version
    QuaZipVersion   = $quazipVersion
    ClipperVersion  = $clipperVersion
    BoostVersion    = "1.$boostMinor.0"
    BoostDirectory  = "boost_1_$boostMinor`_0"
    SvgppVersion    = $svgppVersion
    NgspiceVersion  = $ngspiceVersion
}
