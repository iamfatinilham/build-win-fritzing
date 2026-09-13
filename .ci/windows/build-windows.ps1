[CmdletBinding()]
param(
    [ValidateSet('x64', 'arm64')]
    [string]$Architecture = 'x64',
    [string]$NgspiceArchiveUrl,
    [string]$FritzingRef = 'develop',
    [string]$FritzingPartsRef = 'develop',
    [string]$FritzingAppPath,
    [string]$FritzingPartsPath
)

$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'

# Fritzing's .pri files locate dependencies two levels above those .pri files:
# one directory above phoenix.pro. Keep the app, parts, and every dependency
# side by side in work/; changing that layout breaks upstream auto-detection.
$root = (Resolve-Path -LiteralPath '.').Path
$profile = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'dependency-profile.psd1')
$contractReader = Join-Path $PSScriptRoot 'Get-FritzingBuildContract.ps1'
$expectedMachine = if ($Architecture -eq 'x64') { [uint16]0x8664 } else { [uint16]0xAA64 }

function Invoke-Checked {
    param(
        [Parameter(Mandatory)][string]$Command,
        [string[]]$Arguments = @(),
        [string]$Description = $Command
    )
    Write-Host "> $Description"
    & $Command @Arguments
    $exitCode = $LASTEXITCODE
    if ($exitCode -ne 0) { throw "$Description failed with exit code $exitCode." }
}

function Invoke-Download {
    param(
        [Parameter(Mandatory)][string]$Uri,
        [Parameter(Mandatory)][string]$OutFile,
        [Parameter(Mandatory)][ValidateSet('zip', 'gzip', '7z', 'archive')][string]$ExpectedArchive
    )
    $attempts = 4
    for ($attempt = 1; $attempt -le $attempts; $attempt++) {
        try {
            Remove-Item -LiteralPath $OutFile -Force -ErrorAction SilentlyContinue
            Write-Host "Downloading ($attempt/$attempts): $Uri"
            # SourceForge serves an HTML landing page to Invoke-WebRequest on
            # GitHub's Windows image. curl.exe follows the mirror redirect and
            # is also more reliable for the other binary source archives.
            if (Get-Command 'curl.exe' -ErrorAction SilentlyContinue) {
                & curl.exe --fail --location --silent --show-error --retry 2 --retry-all-errors --output $OutFile $Uri
                if ($LASTEXITCODE -ne 0) { throw "curl.exe failed with exit code $LASTEXITCODE." }
            } else {
                Invoke-WebRequest -Uri $Uri -OutFile $OutFile -MaximumRedirection 10
            }
            if (-not (Test-Path -LiteralPath $OutFile) -or (Get-Item -LiteralPath $OutFile).Length -le 0) {
                throw "Download did not create a non-empty file: $OutFile"
            }
            $stream = [System.IO.File]::OpenRead($OutFile)
            try {
                [byte[]]$header = New-Object byte[] 8
                $bytesRead = $stream.Read($header, 0, $header.Length)
            } finally {
                $stream.Dispose()
            }
            $validSignature = switch ($ExpectedArchive) {
                'zip'  { $bytesRead -ge 2 -and $header[0] -eq 0x50 -and $header[1] -eq 0x4B }
                'gzip' { $bytesRead -ge 2 -and $header[0] -eq 0x1F -and $header[1] -eq 0x8B }
                '7z'   { $bytesRead -ge 6 -and $header[0] -eq 0x37 -and $header[1] -eq 0x7A -and $header[2] -eq 0xBC -and $header[3] -eq 0xAF -and $header[4] -eq 0x27 -and $header[5] -eq 0x1C }
                'archive' { ($bytesRead -ge 2 -and (($header[0] -eq 0x50 -and $header[1] -eq 0x4B) -or ($header[0] -eq 0x1F -and $header[1] -eq 0x8B))) -or ($bytesRead -ge 6 -and $header[0] -eq 0x37 -and $header[1] -eq 0x7A -and $header[2] -eq 0xBC -and $header[3] -eq 0xAF -and $header[4] -eq 0x27 -and $header[5] -eq 0x1C) }
            }
            if (-not $validSignature) {
                $actualSignature = if ($bytesRead -gt 0) { [BitConverter]::ToString($header[0..($bytesRead - 1)]) } else { '<empty>' }
                throw "Download is not the expected $ExpectedArchive archive (header: $actualSignature)."
            }
            return
        } catch {
            if ($attempt -eq $attempts) { throw "Could not download $Uri after $attempts attempts. $($_.Exception.Message)" }
            Start-Sleep -Seconds (2 * $attempt)
        }
    }
}

function Require-Path {
    param([Parameter(Mandatory)][string]$Path)
    if (-not (Test-Path -LiteralPath $Path)) { throw "Required path is missing: $Path" }
}

function Get-FirstFile {
    param([Parameter(Mandatory)][string]$Root, [Parameter(Mandatory)][string]$Name)
    $file = Get-ChildItem -LiteralPath $Root -Recurse -File -Filter $Name -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $file) { throw "Could not find $Name below $Root" }
    return $file.FullName
}

function Get-PEMachine {
    param([Parameter(Mandatory)][string]$Path)
    $bytes = [System.IO.File]::ReadAllBytes($Path)
    if ($bytes.Length -lt 0x40) { throw "File is too small to be a PE binary: $Path" }
    $peOffset = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($peOffset -lt 0 -or $peOffset + 6 -gt $bytes.Length) { throw "Invalid PE header offset in $Path" }
    return [BitConverter]::ToUInt16($bytes, $peOffset + 4)
}

function Get-FirstNgspiceDll {
    param([Parameter(Mandatory)][string]$NgspiceRoot)
    $dll = Get-ChildItem -LiteralPath $NgspiceRoot -Recurse -File -Filter 'ngspice.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if (-not $dll) { $dll = Get-ChildItem -LiteralPath $NgspiceRoot -Recurse -File -Filter '*.dll' -ErrorAction SilentlyContinue | Select-Object -First 1 }
    if (-not $dll) { throw "No ngspice DLL was found below $NgspiceRoot" }
    return $dll
}

function Get-GitRevision {
    param([Parameter(Mandatory)][string]$Repository)
    $revision = (& git -C $Repository rev-parse HEAD).Trim()
    if ($LASTEXITCODE -ne 0 -or [string]::IsNullOrWhiteSpace($revision)) { throw "Could not determine the Git revision for $Repository" }
    return $revision
}

function Resolve-FritzingSource {
    param([string]$Path, [string]$Repository, [string]$Ref, [string]$Name, [string]$RequiredFile)
    if (Test-Path -LiteralPath $Path) {
        $resolved = (Resolve-Path -LiteralPath $Path).Path
        Require-Path (Join-Path $resolved '.git')
        # Self-hosted runners keep their workspaces. Refresh an existing clone
        # explicitly so a manual request for develop, a tag, or a commit can
        # never silently rebuild the previous run's source revision.
        if ($Ref -match '^[0-9a-fA-F]{40}$') {
            & git -C $resolved cat-file -e "$Ref^{commit}"
            if ($LASTEXITCODE -eq 0) {
                Invoke-Checked git @('-C', $resolved, 'checkout', '--force', '--detach', $Ref) "Checkout existing $Name commit $Ref"
            } else {
                Invoke-Checked git @('-C', $resolved, 'fetch', '--depth', '1', 'origin', $Ref) "Fetch $Name commit $Ref"
                Invoke-Checked git @('-C', $resolved, 'checkout', '--force', '--detach', 'FETCH_HEAD') "Checkout $Name commit $Ref"
            }
        } else {
            Invoke-Checked git @('-C', $resolved, 'fetch', '--depth', '1', 'origin', $Ref) "Fetch $Name ref $Ref"
            Invoke-Checked git @('-C', $resolved, 'checkout', '--force', '--detach', 'FETCH_HEAD') "Checkout $Name ref $Ref"
        }
        Require-Path (Join-Path $resolved $RequiredFile)
        return $resolved
    }
    New-Item -ItemType Directory -Force -Path (Split-Path -Parent $Path) | Out-Null
    if ($Ref -match '^[0-9a-fA-F]{40}$') {
        Invoke-Checked git @('clone', '--depth', '1', $Repository, $Path) "Clone $Name"
        Invoke-Checked git @('-C', $Path, 'fetch', '--depth', '1', 'origin', $Ref) "Fetch $Name revision $Ref"
        Invoke-Checked git @('-C', $Path, 'checkout', '--detach', $Ref) "Checkout $Name revision $Ref"
    } else {
        Invoke-Checked git @('clone', '--depth', '1', '--branch', $Ref, $Repository, $Path) "Clone $Name ref $Ref"
    }
    $resolved = (Resolve-Path -LiteralPath $Path).Path
    Require-Path (Join-Path $resolved $RequiredFile)
    return $resolved
}

function Test-DependencyLayout {
    param([pscustomobject]$BuildContract, [string]$QtVersion)
    try {
        $libgitRoot = Join-Path $dependencyRoot "libgit2-$($BuildContract.Libgit2Version)"
        $quazipRoot = Join-Path $dependencyRoot "quazip-$QtVersion-$($BuildContract.QuaZipVersion)intuisphere"
        $clipperRoot = Join-Path $dependencyRoot "Clipper1-$($BuildContract.ClipperVersion)"
        $boostRoot = Join-Path $dependencyRoot $BuildContract.BoostDirectory
        $svgppRoot = Join-Path $dependencyRoot "svgpp-$($BuildContract.SvgppVersion)"
        $ngspiceRoot = Join-Path $dependencyRoot "ngspice-$($BuildContract.NgspiceVersion)"
        Require-Path (Join-Path $dependencyRoot 'zlib\build\zlibstatic.lib')
        Require-Path (Join-Path $libgitRoot 'include\git2.h')
        Require-Path (Join-Path $libgitRoot 'lib\git2.lib')
        Require-Path (Join-Path $quazipRoot 'lib\quazip1-qt6.lib')
        Require-Path (Join-Path $quazipRoot "include\QuaZip-Qt6-$($BuildContract.QuaZipVersion)\quazip")
        Require-Path (Join-Path $clipperRoot 'include\polyclipping\clipper.hpp')
        Require-Path (Join-Path $clipperRoot 'lib\polyclipping.lib')
        Require-Path (Join-Path $boostRoot 'boost\version.hpp')
        Require-Path (Join-Path $svgppRoot 'include')
        Require-Path (Join-Path $ngspiceRoot 'include')
        $ngspiceDll = Get-FirstNgspiceDll $ngspiceRoot
        if ((Get-PEMachine $ngspiceDll.FullName) -ne $expectedMachine) { throw "Cached ngspice DLL does not match $Architecture." }
        return $true
    } catch {
        Write-Host "Dependency cache is incomplete or incompatible: $($_.Exception.Message)"
        return $false
    }
}

function Clear-DependencyLayout {
    param([pscustomobject]$BuildContract, [string]$QtVersion)
    # Remove only build-owned paths beside Fritzing's source. This also clears
    # interrupted archive extraction trees, making a retry deterministic.
    $paths = @(
        'zlib', "zlib-$($profile.ZlibVersion)", 'zlib.tar.gz',
        "libgit2-$($BuildContract.Libgit2Version)", 'libgit2.tar.gz',
        "quazip-$($BuildContract.QuaZipVersion)", 'quazip.tar.gz',
        "quazip-$QtVersion-$($BuildContract.QuaZipVersion)intuisphere",
        "Clipper1-$($BuildContract.ClipperVersion)", 'clipper.zip', 'clipper-src',
        $BuildContract.BoostDirectory, 'boost.tar.gz',
        "svgpp-$($BuildContract.SvgppVersion)", 'svgpp.tar.gz',
        "ngspice-$($BuildContract.NgspiceVersion)", 'ngspice-x64.7z', 'ngspice-arm64.7z', 'ngspice-extract'
    )
    foreach ($path in $paths) {
        $fullPath = Join-Path $dependencyRoot $path
        if (Test-Path -LiteralPath $fullPath) { Remove-Item -LiteralPath $fullPath -Recurse -Force }
    }
}

function Build-Dependencies {
    param([pscustomobject]$BuildContract, [string]$QtVersion)
    Clear-DependencyLayout $BuildContract $QtVersion
    $zlibVersion = $profile.ZlibVersion; $policyVersion = $profile.CMakePolicyVersionMinimum
    $libgit2Version = $BuildContract.Libgit2Version; $quazipVersion = $BuildContract.QuaZipVersion; $clipperVersion = $BuildContract.ClipperVersion
    $boostVersion = $BuildContract.BoostVersion; $boostDirectory = $BuildContract.BoostDirectory; $svgppVersion = $BuildContract.SvgppVersion; $ngspiceVersion = $BuildContract.NgspiceVersion

    Push-Location $dependencyRoot
    try {
    Invoke-Download "https://github.com/madler/zlib/releases/download/v$zlibVersion/zlib-$zlibVersion.tar.gz" 'zlib.tar.gz' 'gzip'
    Invoke-Checked tar @('-xzf', 'zlib.tar.gz') 'Extract zlib'; Remove-Item -LiteralPath 'zlib.tar.gz' -Force
    if (-not (Test-Path -LiteralPath "zlib-$zlibVersion")) { throw 'zlib archive layout changed.' }
    Rename-Item -LiteralPath "zlib-$zlibVersion" -NewName 'zlib'; New-Item -ItemType Directory -Force -Path 'zlib\build' | Out-Null
    Push-Location 'zlib\build'
    try {
        Invoke-Checked cmake @('-G', 'NMake Makefiles', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_POLICY_VERSION_MINIMUM=$policyVersion", '..') 'Configure zlib'
        Invoke-Checked nmake @() 'Build zlib'; Require-Path 'zs.lib'; Copy-Item -LiteralPath 'zs.lib' -Destination 'zlibstatic.lib' -Force; Copy-Item -LiteralPath 'zconf.h' -Destination '..\zconf.h' -Force
    } finally { Pop-Location }

    Invoke-Download "https://github.com/libgit2/libgit2/archive/refs/tags/v$libgit2Version.tar.gz" 'libgit2.tar.gz' 'gzip'
    Invoke-Checked tar @('-xzf', 'libgit2.tar.gz') 'Extract libgit2'; Remove-Item -LiteralPath 'libgit2.tar.gz' -Force
    $libgitRoot = "libgit2-$libgit2Version"; Require-Path $libgitRoot; New-Item -ItemType Directory -Force -Path "$libgitRoot\build", "$libgitRoot\lib" | Out-Null
    Push-Location "$libgitRoot\build"
    try {
        Invoke-Checked cmake @('-G', 'NMake Makefiles', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_POLICY_VERSION_MINIMUM=$policyVersion", '-DBUILD_SHARED_LIBS=OFF', '-DBUILD_TESTS=OFF', '-DUSE_BUNDLED_ZLIB=OFF', "-DZLIB_LIBRARY=$dependencyRoot\zlib\build\zlibstatic.lib", "-DZLIB_INCLUDE_DIR=$dependencyRoot\zlib", '..') 'Configure libgit2'
        Invoke-Checked nmake @() 'Build libgit2'
    } finally { Pop-Location }
    Copy-Item -LiteralPath (Get-FirstFile "$libgitRoot\build" 'git2.lib') -Destination "$libgitRoot\lib\git2.lib" -Force

    Invoke-Download "https://github.com/stachenov/quazip/archive/refs/tags/v$quazipVersion.tar.gz" 'quazip.tar.gz' 'gzip'
    Invoke-Checked tar @('-xzf', 'quazip.tar.gz') 'Extract QuaZip'; Remove-Item -LiteralPath 'quazip.tar.gz' -Force
    $quazipSource = "quazip-$quazipVersion"; Require-Path $quazipSource; New-Item -ItemType Directory -Force -Path "$quazipSource\build" | Out-Null
    Push-Location "$quazipSource\build"
    try {
        Invoke-Checked cmake @('-G', 'NMake Makefiles', '-DCMAKE_BUILD_TYPE=Release', "-DCMAKE_POLICY_VERSION_MINIMUM=$policyVersion", '-DQUAZIP_QT_MAJOR_VERSION=6', "-DZLIB_LIBRARY=$dependencyRoot\zlib\build\zlibstatic.lib", "-DZLIB_INCLUDE_DIR=$dependencyRoot\zlib", '..') 'Configure QuaZip'
        Invoke-Checked nmake @() 'Build QuaZip'
    } finally { Pop-Location }
    $quazipRoot = "quazip-$QtVersion-$quazipVersion`intuisphere"; New-Item -ItemType Directory -Force -Path "$quazipRoot\lib", "$quazipRoot\include\QuaZip-Qt6-$quazipVersion\quazip" | Out-Null
    Copy-Item -LiteralPath (Get-FirstFile "$quazipSource\build" 'quazip1-qt6.lib') -Destination "$quazipRoot\lib\quazip1-qt6.lib" -Force
    $quazipDll = Get-ChildItem -LiteralPath "$quazipSource\build" -Recurse -File -Filter 'quazip1-qt6.dll' -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($quazipDll) { Copy-Item -LiteralPath $quazipDll.FullName -Destination "$quazipRoot\lib" -Force }
    Copy-Item -Path "$quazipSource\quazip\*.h" -Destination "$quazipRoot\include\QuaZip-Qt6-$quazipVersion\quazip" -Force
    Remove-Item -LiteralPath $quazipSource -Recurse -Force

    # This is the direct file endpoint for the pinned official Clipper 6.4.2
    # release; do not use SourceForge's HTML /download landing-page URL.
    Invoke-Download "https://downloads.sourceforge.net/project/polyclipping/clipper_ver$clipperVersion.zip" 'clipper.zip' 'zip'
    Expand-Archive -LiteralPath 'clipper.zip' -DestinationPath 'clipper-src' -Force; Remove-Item -LiteralPath 'clipper.zip' -Force
    $clipperRoot = "Clipper1-$clipperVersion"; New-Item -ItemType Directory -Force -Path "$clipperRoot\include\polyclipping", "$clipperRoot\lib" | Out-Null
    $clipperHeader = Get-ChildItem -LiteralPath 'clipper-src' -Recurse -File -Filter 'clipper.hpp' | Select-Object -First 1
    if (-not $clipperHeader) { throw 'clipper.hpp was not found in the downloaded archive.' }
    Copy-Item -LiteralPath $clipperHeader.FullName, (Join-Path $clipperHeader.DirectoryName 'clipper.cpp') -Destination "$clipperRoot\include\polyclipping" -Force
    Push-Location $clipperRoot
    try { Invoke-Checked cl @('/c', '/O2', '/EHsc', '/MD', '/Iinclude\polyclipping', 'include\polyclipping\clipper.cpp') 'Compile Clipper'; Invoke-Checked lib @('/OUT:lib\polyclipping.lib', 'clipper.obj') 'Archive Clipper' } finally { Pop-Location }
    Remove-Item -LiteralPath 'clipper-src' -Recurse -Force

    Invoke-Download "https://archives.boost.io/release/$boostVersion/source/$boostDirectory.tar.gz" 'boost.tar.gz' 'gzip'
    Invoke-Checked tar @('-xzf', 'boost.tar.gz') 'Extract Boost'; Remove-Item -LiteralPath 'boost.tar.gz' -Force; Require-Path $boostDirectory
    Invoke-Download "https://github.com/svgpp/svgpp/archive/refs/tags/v$svgppVersion.tar.gz" 'svgpp.tar.gz' 'gzip'
    Invoke-Checked tar @('-xzf', 'svgpp.tar.gz') 'Extract SVG++'; Remove-Item -LiteralPath 'svgpp.tar.gz' -Force; Require-Path "svgpp-$svgppVersion"

    if ([string]::IsNullOrWhiteSpace($NgspiceArchiveUrl)) {
        if ($Architecture -ne 'x64') { throw 'ARM64 requires -NgspiceArchiveUrl. The public ngspice Windows archive is x64-only.' }
        $NgspiceArchiveUrl = "https://sourceforge.net/projects/ngspice/files/ng-spice-rework/old-releases/$ngspiceVersion/ngspice-$ngspiceVersion`_dll_64.7z/download"
    }
    $ngspiceArchive = "ngspice-$Architecture.7z"; Invoke-Download $NgspiceArchiveUrl $ngspiceArchive 'archive'; Invoke-Checked 7z @('x', $ngspiceArchive, '-ongspice-extract') 'Extract ngspice'; Remove-Item -LiteralPath $ngspiceArchive -Force
    $ngspiceCandidates = @((Get-Item -LiteralPath 'ngspice-extract')) + @(Get-ChildItem -LiteralPath 'ngspice-extract' -Directory -Recurse)
    $ngspiceCandidate = $ngspiceCandidates | Where-Object { Test-Path -LiteralPath (Join-Path $_.FullName 'include') } | Select-Object -First 1
    if (-not $ngspiceCandidate) { throw "The $Architecture ngspice archive must contain a directory with include/." }
    Move-Item -LiteralPath $ngspiceCandidate.FullName -Destination "ngspice-$ngspiceVersion"; Remove-Item -LiteralPath 'ngspice-extract' -Recurse -Force
    $ngspiceDll = Get-FirstNgspiceDll "ngspice-$ngspiceVersion"
    if ((Get-PEMachine $ngspiceDll.FullName) -ne $expectedMachine) { throw "The ngspice DLL does not match the requested $Architecture architecture." }
    } finally {
        Pop-Location
    }
}

foreach ($command in 'cmake', 'nmake', 'cl', 'lib', 'qmake', 'windeployqt', '7z', 'git', 'tar', 'curl.exe') {
    if (-not (Get-Command $command -ErrorAction SilentlyContinue)) { throw "Required $Architecture build tool is unavailable: $command" }
}
if (-not $env:QT_ROOT_DIR -or -not (Test-Path -LiteralPath "$env:QT_ROOT_DIR\bin\qmake.exe")) { throw 'QT_ROOT_DIR must point to the selected Qt MSVC installation.' }
$env:Path = "$env:QT_ROOT_DIR\bin;$env:Path"

$appPath = Resolve-FritzingSource $(if ($FritzingAppPath) { $FritzingAppPath } else { Join-Path $root 'work\fritzing-app' }) 'https://github.com/fritzing/fritzing-app.git' $FritzingRef 'fritzing-app' 'phoenix.pro'
$partsPath = Resolve-FritzingSource $(if ($FritzingPartsPath) { $FritzingPartsPath } else { Join-Path $root 'work\fritzing-parts' }) 'https://github.com/fritzing/fritzing-parts.git' $FritzingPartsRef 'fritzing-parts' '.git'
$dependencyRoot = Split-Path -Parent $appPath
Require-Path $dependencyRoot
Write-Host "Using Fritzing dependency root: $dependencyRoot"
$contract = & $contractReader -ProjectFile (Join-Path $appPath 'phoenix.pro')
$qmakeVersion = (& "$env:QT_ROOT_DIR\bin\qmake.exe" -query QT_VERSION).Trim()
if ($LASTEXITCODE -ne 0) { throw 'qmake could not report its Qt version.' }
if ([version]$qmakeVersion -lt [version]$contract.QtMinimum -or [version]$qmakeVersion -gt [version]$contract.QtMaximum) { throw "Qt $qmakeVersion is outside Fritzing's declared supported range $($contract.QtMinimum) through $($contract.QtMaximum)." }
Write-Host "Using Qt $qmakeVersion; Fritzing accepts $($contract.QtRange)."

if ($Architecture -eq 'arm64') {
    $projectFile = Join-Path $appPath 'phoenix.pro'; $projectText = Get-Content -LiteralPath $projectFile -Raw
    if ($projectText -notmatch 'contains\s*\(\s*QMAKE_TARGET\.arch\s*,\s*arm64\s*\)') {
        $pattern = 'contains\s*\(\s*QMAKE_TARGET\.arch\s*,\s*x86_64\s*\)\s*\{'
        if (-not [regex]::IsMatch($projectText, $pattern)) { throw 'The upstream ARM64 output-path condition changed. Update the narrowly-scoped ARM64 CI patch before building.' }
        $projectText = [regex]::Replace($projectText, $pattern, 'contains(QMAKE_TARGET.arch, x86_64)|contains(QMAKE_TARGET.arch, arm64) {', 1)
        Set-Content -LiteralPath $projectFile -Value $projectText -Encoding utf8NoBOM -NoNewline
    }
}

if (-not (Test-DependencyLayout $contract $qmakeVersion)) { Build-Dependencies $contract $qmakeVersion }
if (-not (Test-DependencyLayout $contract $qmakeVersion)) { throw 'Dependency build completed but the required Fritzing layout is still incomplete.' }

# A self-hosted runner can reuse its workspace. Only clean derived directories
# inside this build workspace, after the source/dependency validation above, so
# a failed old build cannot supply an executable or ZIP to this run.
$managedAppPath = Join-Path $root 'work\fritzing-app'
if ($appPath -eq $managedAppPath) {
    $previousRelease = Join-Path $root 'work\release64'
    if (Test-Path -LiteralPath $previousRelease) { Remove-Item -LiteralPath $previousRelease -Recurse -Force }
}
$previousArtifacts = Join-Path $root 'artifacts'
if (Test-Path -LiteralPath $previousArtifacts) { Remove-Item -LiteralPath $previousArtifacts -Recurse -Force }

Remove-Item -LiteralPath (Join-Path $appPath '.qmake.cache'), (Join-Path $appPath '.qmake.stash') -Force -ErrorAction SilentlyContinue
Push-Location $appPath
try {
    $qmakeArguments = @('phoenix.pro', "LIBS+=-L$dependencyRoot\zlib\build -lzlibstatic -ladvapi32 -lwinhttp -lcrypt32 -lole32 -lrpcrt4 -lws2_32")
    Invoke-Checked qmake $qmakeArguments 'Configure Fritzing with qmake'; Invoke-Checked nmake @('release') 'Build Fritzing'
} finally { Pop-Location }

$release = Join-Path (Split-Path -Parent $appPath) 'release64'; $exe = Join-Path $release 'Fritzing.exe'; Require-Path $exe
if ((Get-Item -LiteralPath $exe).Length -lt 1MB) { throw 'Fritzing.exe is unexpectedly small.' }
if ((Get-PEMachine $exe) -ne $expectedMachine) { throw "Fritzing.exe does not match the requested $Architecture architecture." }
Push-Location $release; try { Invoke-Checked windeployqt @('--release', 'Fritzing.exe') 'Deploy Qt runtime' } finally { Pop-Location }

$quazipRoot = Join-Path $dependencyRoot "quazip-$qmakeVersion-$($contract.QuaZipVersion)intuisphere"; Copy-Item -Path "$quazipRoot\lib\*.dll" -Destination $release -Force -ErrorAction SilentlyContinue
$ngspiceRoot = Join-Path $dependencyRoot "ngspice-$($contract.NgspiceVersion)"; Get-ChildItem -LiteralPath $ngspiceRoot -Recurse -File -Filter '*.dll' | ForEach-Object { Copy-Item -LiteralPath $_.FullName -Destination $release -Force }
Require-Path "$env:QT_ROOT_DIR\bin\Qt6Core5Compat.dll"; Copy-Item -LiteralPath "$env:QT_ROOT_DIR\bin\Qt6Core5Compat.dll" -Destination $release -Force
foreach ($directory in 'help', 'sketches', 'translations') { $sourceDirectory = Join-Path $appPath $directory; Require-Path $sourceDirectory; Copy-Item -LiteralPath $sourceDirectory -Destination $release -Recurse -Force }
Copy-Item -LiteralPath $partsPath -Destination (Join-Path $release 'fritzing-parts') -Recurse -Force
Require-Path (Join-Path $release 'platforms\qwindows.dll'); Require-Path (Join-Path $release 'fritzing-parts')

$versionSource = Get-Content -LiteralPath (Join-Path $appPath 'src\version\version.cpp') -Raw
$versionValues = @(([regex]'m_majorVersion\("(.*?)"\)').Match($versionSource).Groups[1].Value, ([regex]'m_minorVersion\("(.*?)"\)').Match($versionSource).Groups[1].Value, ([regex]'m_minorSubVersion\("(.*?)"\)').Match($versionSource).Groups[1].Value)
$modifier = ([regex]'m_modifier\("(.*?)"\)').Match($versionSource).Groups[1].Value
if ($versionValues | Where-Object { [string]::IsNullOrWhiteSpace($_) }) { throw 'Could not extract a complete Fritzing version from version.cpp.' }
$fritzingVersion = "$($versionValues[0]).$($versionValues[1]).$($versionValues[2])$modifier"; $fritzingCommit = Get-GitRevision $appPath; $partsCommit = Get-GitRevision $partsPath
$manifest = [ordered]@{ schema = 1; created_utc = [DateTime]::UtcNow.ToString('o'); architecture = $Architecture; fritzing = [ordered]@{ version = $fritzingVersion; commit = $fritzingCommit; requested_ref = $FritzingRef }; fritzing_parts = [ordered]@{ commit = $partsCommit; requested_ref = $FritzingPartsRef }; qt = [ordered]@{ version = $qmakeVersion; supported_range = $contract.QtRange }; dependencies = [ordered]@{ zlib = $profile.ZlibVersion; libgit2 = $contract.Libgit2Version; quazip = $contract.QuaZipVersion; clipper = $contract.ClipperVersion; boost = $contract.BoostVersion; svgpp = $contract.SvgppVersion; ngspice = $contract.NgspiceVersion } }
$manifest | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $release 'build-manifest.json') -Encoding utf8NoBOM

$artifactsDirectory = Join-Path $root 'artifacts'; New-Item -ItemType Directory -Force -Path $artifactsDirectory | Out-Null
$archive = Join-Path $artifactsDirectory "Fritzing-$fritzingVersion-Portable-Windows-$Architecture.zip"; Remove-Item -LiteralPath $archive -Force -ErrorAction SilentlyContinue
Compress-Archive -Path (Join-Path $release '*') -DestinationPath $archive -CompressionLevel Optimal; Require-Path $archive
if ((Get-Item -LiteralPath $archive).Length -le 0) { throw "Created artifact is empty: $archive" }; Write-Host "Created $archive"

if ($env:GITHUB_OUTPUT) { @("fritzing_version=$fritzingVersion", "fritzing_commit=$fritzingCommit", "parts_commit=$partsCommit", "qt_version=$qmakeVersion", "artifact=$archive") | Add-Content -LiteralPath $env:GITHUB_OUTPUT -Encoding utf8 }
