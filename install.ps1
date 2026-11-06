#!/usr/bin/env pwsh
# Copyright (c) 2026, MariaDB plc.
#
# This program is free software; you can redistribute it and/or modify
# it under the terms of the GNU General Public License as published by
# the Free Software Foundation; version 2 of the License.
#
# This program is distributed in the hope that it will be useful,
# but WITHOUT ANY WARRANTY; without even the implied warranty of
# MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the
# GNU General Public License for more details.
#
# You should have received a copy of the GNU General Public License
# along with this program; if not, write to the Free Software
# Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA 02110-1335 USA

<#
.SYNOPSIS
  mariadb-restd installer for Windows. The counterpart of install.sh.

.DESCRIPTION
  Picks the Windows package from a release, verifies its checksum, unpacks it
  into <prefix>\<version> and writes .cmd shims for its programs into the bin
  directory. Two versions are kept. Like install.sh it is data-driven: the
  package list is read from the release's SHA256SUMS rather than hardcoded, so
  this script does not go stale as versions come and go.

  There is only an x64 package (GraalVM, which the JIT executor library is
  built with, has no Windows ARM64 release); Windows on ARM runs it under
  emulation.

  Piped into a shell, parameters cannot be passed the usual way, so every one of
  them also has an environment variable:

    irm https://github.com/mariadb-corporation/rest-daemon/raw/main/install.ps1 | iex

    $env:MARIADB_RESTD_PRERELEASE = 1
    irm https://github.com/mariadb-corporation/rest-daemon/raw/main/install.ps1 | iex

  Or, to pass parameters properly, create a scriptblock rather than piping:

    & ([scriptblock]::Create((irm https://github.com/mariadb-corporation/rest-daemon/raw/main/install.ps1))) -PreRelease

.PARAMETER PreRelease
  Install the newest release even if it is a prerelease. Without it, prereleases
  are skipped, exactly as /releases/latest/ skips them.
  Environment: MARIADB_RESTD_PRERELEASE

.PARAMETER Tag
  Install this release tag rather than the newest. Wins over -PreRelease, since
  it already names the release to install.
  Environment: MARIADB_RESTD_TAG

.PARAMETER Sha256Sums
  A local copy of the release's SHA256SUMS, read instead of the one published
  with the release, so the package has to match checksums the caller keeps.
  Needs -Tag, since a SHA256SUMS lists the packages of one release.
  Environment: MARIADB_RESTD_SHA256SUMS

.PARAMETER Repo
  The owner/repo to install from. It has to be public.
  Environment: MARIADB_RESTD_REPO

.PARAMETER Prefix
  Where the versions are unpacked (default %LOCALAPPDATA%\Programs\mariadb-restd).
  Environment: MARIADB_RESTD_PREFIX

.PARAMETER BinDir
  Where the shims are written (default <prefix>\bin).
  Environment: MARIADB_RESTD_BINDIR

.PARAMETER AddToPath
  Add the shim directory to the user PATH. Off by default: editing a user's
  environment is not something a piped installer should do uninvited.
  Environment: MARIADB_RESTD_ADDTOPATH
#>
[CmdletBinding()]
param(
    [switch] $PreRelease,
    [switch] $AddToPath,
    [string] $Tag,
    [string] $Sha256Sums,
    [string] $Repo,
    [string] $Prefix,
    [string] $BinDir
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Windows PowerShell 5.1 draws a progress bar for every Invoke-WebRequest, which
# costs far more than the download itself on an 85 MB package. It also
# negotiates TLS 1.0 by default on older setups, which github.com no longer
# accepts.
$ProgressPreference = 'SilentlyContinue'
try {
    [Net.ServicePointManager]::SecurityProtocol =
        [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
} catch {
    # PowerShell 7 on .NET Core manages this itself and the type may be absent.
}

function Info([string] $Message) { Write-Host "==> $Message" }

function Die([string] $Message) {
    # Written whole rather than through Write-Error, whose wrapping and
    # "at line:1 char:1" framing turn a formatted block into noise.
    [Console]::Error.WriteLine("install.ps1: $Message")
    exit 1
}

# The programs a package has in bin\, each given a shim. mariadb-restd itself
# has to be there; the others get one when the package has them.
$Programs = @('mariadb-restd', 'mariadb-restd-passwd', 'mariadb-restd-keyring',
              'mariadb-restd-plugin-info')

# --------------------------------------------------------------------------
# Settings. Every parameter falls back to an environment variable, because the
# documented one-liner pipes this script into iex, where arguments cannot reach.
# --------------------------------------------------------------------------
# The default is a scriptblock, not a value: computing it eagerly would evaluate
# a LOCALAPPDATA-derived path even when -Prefix was passed, and fail on any
# machine where that variable is unset.
function Fallback([string] $Value, [string] $EnvName, [scriptblock] $Default) {
    if ($Value) { return $Value }
    $fromEnv = [Environment]::GetEnvironmentVariable($EnvName)
    if ($fromEnv) { return $fromEnv }
    if ($Default) { return (& $Default) }
    return ''
}

$Repo   = Fallback $Repo   'MARIADB_RESTD_REPO'   { 'mariadb-corporation/rest-daemon' }
$Tag    = Fallback $Tag    'MARIADB_RESTD_TAG'    $null
$Sha256Sums = Fallback $Sha256Sums 'MARIADB_RESTD_SHA256SUMS' $null
$Prefix = Fallback $Prefix 'MARIADB_RESTD_PREFIX' {
    if (-not $env:LOCALAPPDATA) {
        Die "LOCALAPPDATA is not set, so there is no default install location.
  Pass -Prefix, or set MARIADB_RESTD_PREFIX."
    }
    Join-Path $env:LOCALAPPDATA 'Programs\mariadb-restd'
}
$BinDir = Fallback $BinDir 'MARIADB_RESTD_BINDIR' { Join-Path $Prefix 'bin' }

# Where the shims (written under "Shims" below) will point, worked out before
# anything is downloaded, so a prefix they cannot name stops the install here
# rather than after unpacking.
#
# Paths are resolved as PowerShell resolves them (against its current location,
# not the process's), so a relative -Prefix or -BinDir compares correctly, and a
# relative -BinDir is not written into PATH as it was typed.
function Get-FullPath([string] $Path) {
    $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($Path).TrimEnd('\')
}
$BinDir = Get-FullPath $BinDir
$prefixFull  = Get-FullPath $Prefix
# Trimmed like $prefixFull, so a prefix at a drive root still compares equal.
$binParent   = (Split-Path -Parent $BinDir).TrimEnd('\')
$relativeDir = '%~dp0..'
# A shim is plain ASCII: cmd reads a batch file in the console's current
# code page, which need not be the OEM one, so a non-ASCII byte reads
# differently from console to console. A prefix under the user's own
# directories, where a non-ASCII user name comes from, is written through the
# variable instead, which cmd expands in Unicode. cmd also expands %...% inside
# quotes, so a literal % in the rest of the path is doubled.
$absoluteDir = $prefixFull.Replace('%', '%%')
foreach ($var in @('LOCALAPPDATA', 'USERPROFILE')) {
    $value = [Environment]::GetEnvironmentVariable($var)
    if (-not $value) { continue }
    $value = $value.TrimEnd('\')
    if ($prefixFull -eq $value -or
        $prefixFull.StartsWith("$value\", [StringComparison]::OrdinalIgnoreCase)) {
        $absoluteDir = "%$var%" + $prefixFull.Substring($value.Length).Replace('%', '%%')
        break
    }
}
$versionRoot = if ($binParent -eq $prefixFull) { $relativeDir } else { $absoluteDir }
if ($versionRoot -match '[^\x00-\x7F]') {
    Die "$prefixFull has characters a command file cannot hold reliably.
  Use a -BinDir inside the prefix, such as $prefixFull\bin, or a -Prefix whose
  path is plain ASCII or lies under %LOCALAPPDATA% or %USERPROFILE%."
}

if (-not $PreRelease) { $PreRelease = [bool] (Fallback '' 'MARIADB_RESTD_PRERELEASE' $null) }
if (-not $AddToPath)  { $AddToPath  = [bool] (Fallback '' 'MARIADB_RESTD_ADDTOPATH' $null) }

if ($PreRelease) {
    $PreReleaseHint = @'
  Prereleases are already enabled. Name a release outright if the one you want
  is not the newest:

      $env:MARIADB_RESTD_TAG = '<tag>'
'@
} else {
    $PreReleaseHint = @'
  A prerelease is never 'latest'. Reach the newest one with -PreRelease, or name
  a release outright:

      $env:MARIADB_RESTD_TAG = '<tag>'
'@
}

# A local SHA256SUMS lets whoever runs this decide which checksums the package
# has to match, rather than trusting the file published next to it -- the
# assets of a release can be replaced, a copy kept elsewhere cannot. It lists
# the assets of one release, so the release has to be named too.
if ($Sha256Sums) {
    if (-not $Tag) {
        Die "-Sha256Sums (MARIADB_RESTD_SHA256SUMS) needs -Tag (MARIADB_RESTD_TAG).
  A SHA256SUMS lists the packages of one release, so name that release:

      `$env:MARIADB_RESTD_TAG = '<tag>'"
    }
    if (-not (Test-Path -LiteralPath $Sha256Sums -PathType Leaf)) {
        Die "-Sha256Sums (MARIADB_RESTD_SHA256SUMS) is not a file: $Sha256Sums"
    }
    # Resolved now, against PowerShell's location, before anything changes it.
    $Sha256Sums = Get-FullPath $Sha256Sums
}

# --------------------------------------------------------------------------
# Platform
# --------------------------------------------------------------------------
# PROCESSOR_ARCHITECTURE reports the architecture of the *process*. A 32-bit
# PowerShell on 64-bit Windows would call itself x86, which ARCHITEW6432
# corrects; on ARM64 Windows, a PowerShell started by an x64 program runs
# emulated and says AMD64. The system environment in the registry holds the
# machine's own architecture in every case, so it is asked first. The value is
# asked for by name inside try: under strict mode, a missing key or value would
# otherwise throw on the property read instead of falling back.
$rawArch = $null
try {
    $rawArch = (Get-ItemProperty -ErrorAction Stop -Name PROCESSOR_ARCHITECTURE `
        -Path 'HKLM:\SYSTEM\CurrentControlSet\Control\Session Manager\Environment').PROCESSOR_ARCHITECTURE
} catch {
    # Unreadable or absent: the process's own view below is the fallback.
}
if (-not $rawArch) { $rawArch = $env:PROCESSOR_ARCHITEW6432 }
if (-not $rawArch) { $rawArch = $env:PROCESSOR_ARCHITECTURE }

switch ($rawArch) {
    'AMD64' { $Arch = 'x64'; $ArchNote = '' }
    'ARM64' { $Arch = 'x64'; $ArchNote = ' (the x64 package, run under emulation)' }
    'x86'   { Die "32-bit Windows is not supported; no 32-bit package is built." }
    default { Die "unrecognised processor architecture '$rawArch'." }
}

Info "Detected: windows, $($rawArch.ToLowerInvariant())$ArchNote"

# --------------------------------------------------------------------------
# Release resolution
# --------------------------------------------------------------------------
# A pinned tag and the latest stable release are both reachable by a plain
# download URL: /releases/latest/download/ is a permanent URL GitHub redirects to
# the newest non-prerelease release, so nothing here needs to know the version
# and this script never goes stale. Only the newest prerelease has to be looked
# up first, because it is invisible to /releases/latest: the releases are listed
# through the GitHub API and the newest one taken.
$ResolvePreRelease = $false
if ($Tag) {
    $Base        = "https://github.com/$Repo/releases/download/$Tag"
    $ReleaseDesc = $Tag
} elseif ($PreRelease) {
    $ResolvePreRelease = $true
    $Base        = ''   # known once the release is resolved
    $ReleaseDesc = 'newest, prereleases included'
} else {
    $Base        = "https://github.com/$Repo/releases/latest/download"
    $ReleaseDesc = 'latest'
}

# Every release is public, so once the tag is known the assets are downloaded by
# name like on the other paths -- the GitHub API is only asked for the listing.
# Its anonymous requests are limited to 60 an hour per address, so the API is
# never asked for anything the plain download URLs can provide.
#
# Returns what it resolved rather than assigning across scopes. A $script:
# qualifier would look right and work when this file is run directly, yet bind
# to the caller's scope under [scriptblock]::Create() -- which is exactly how the
# documented one-liner runs it.
function Resolve-PreRelease {
    try {
        $releases = Invoke-RestMethod -Uri "https://api.github.com/repos/$Repo/releases?per_page=20" `
            -Headers @{ 'Accept' = 'application/vnd.github+json' } -UseBasicParsing
    } catch {
        [Console]::Error.WriteLine("  $($_.Exception.Message)`n")
        Die "could not list the releases of $Repo.

  The GitHub API limits anonymous requests to 60 an hour per address, so a
  shared address may have used them up. Naming a release avoids the API:

      `$env:MARIADB_RESTD_TAG = '<tag>'
"
    }

    $release = @($releases) | Where-Object { -not $_.draft } | Select-Object -First 1
    if (-not $release) {
        Die "could not find a published release in $Repo -- is every release a draft?"
    }
    return $release.tag_name
}

function Get-Asset([string] $Name, [string] $OutFile) {
    Invoke-WebRequest -Uri "$Base/$Name" -OutFile $OutFile -UseBasicParsing
}

if ($ResolvePreRelease) {
    $ReleaseDesc = Resolve-PreRelease
    $Base        = "https://github.com/$Repo/releases/download/$ReleaseDesc"
}

$Tmp = Join-Path ([IO.Path]::GetTempPath()) ("mariadb-restd-install-" + [Guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $Tmp -Force | Out-Null
# Read by the finally below, which strict mode does not let read them unset.
$unpackDir = $null
$installMutex = $null
$haveMutex = $false

try {
    # ----------------------------------------------------------------------
    # SHA256SUMS is the manifest. Reading the asset list from the same file that
    # carries the checksums means there is no separate index to drift out of
    # sync with the real assets.
    # ----------------------------------------------------------------------
    $sumsFile = Join-Path $Tmp 'SHA256SUMS'
    if ($Sha256Sums) {
        Info "Reading package list for the $ReleaseDesc release from $Sha256Sums"
        Copy-Item -LiteralPath $Sha256Sums -Destination $sumsFile
    } else {
        Info "Fetching package list from the $ReleaseDesc release"
    }
    try {
        if (-not $Sha256Sums) { Get-Asset 'SHA256SUMS' $sumsFile }
    } catch {
        [Console]::Error.WriteLine("  $($_.Exception.Message)`n")
        # A release that was just found in the listing exists; one that was
        # named or implied may not.
        if ($ResolvePreRelease) {
            Die "could not download SHA256SUMS from release $ReleaseDesc of $Repo.

  The release exists but has no SHA256SUMS file. A release that is still being
  published does not have its files yet; try again in a few minutes."
        }
        Die "could not download SHA256SUMS from the $ReleaseDesc release of $Repo.

  That release may not exist.

$PreReleaseHint
"
    }

    # ----------------------------------------------------------------------
    # Select. One package per OS and CPU, with no platform version in its name,
    # so the suffix identifies it.
    # ----------------------------------------------------------------------
    $suffix   = "-windows-$Arch.zip"
    $manifest = Get-Content $sumsFile | Where-Object { $_.Trim() }
    $entries  = foreach ($line in $manifest) {
        $parts = $line -split '\s+', 2
        if ($parts.Count -eq 2) {
            [pscustomobject]@{ Sum = $parts[0].Trim(); Name = $parts[1].Trim().TrimStart('*') }
        }
    }

    $best = $entries | Where-Object {
        $_.Name.StartsWith('mariadb-restd-') -and $_.Name.EndsWith($suffix)
    } | Select-Object -First 1
    if (-not $best) {
        [Console]::Error.WriteLine("install.ps1: no package for windows / $Arch in the $ReleaseDesc release.")
        [Console]::Error.WriteLine("Available packages:")
        foreach ($e in $entries) { [Console]::Error.WriteLine("  $($e.Name)") }
        exit 1
    }

    Info "Selected $($best.Name)"

    # ----------------------------------------------------------------------
    # Download and verify
    # ----------------------------------------------------------------------
    Info "Downloading"
    $pkg = Join-Path $Tmp $best.Name
    try {
        Get-Asset $best.Name $pkg
    } catch {
        Die "could not download $($best.Name) from release $ReleaseDesc of $Repo.

  $($_.Exception.Message)"
    }

    Info "Verifying checksum"
    $actual = (Get-FileHash -Path $pkg -Algorithm SHA256).Hash.ToLowerInvariant()
    $expected = $best.Sum.ToLowerInvariant()
    if ($actual -ne $expected) {
        Die "checksum mismatch for $($best.Name)
    expected: $expected
    actual:   $actual"
    }

    # ----------------------------------------------------------------------
    # Unpack. The zip holds a single top-level mariadb-restd-<ver>-windows-x64
    # directory, renamed to just the version: the platform is a property of the
    # machine that unpacked it, not something worth repeating in every path a
    # user types.
    #
    # Each run unpacks into a private folder of its own: two runs unpacking the
    # same package into one place trip over each other's files and both fail.
    # The folder is inside the prefix so the move into place stays on one
    # volume, and carries the PID so a later run can tell when it is stale.
    #
    # tar (bsdtar, shipped with Windows since 10 1803) reads zip files and is
    # much faster than Expand-Archive on Windows PowerShell 5.1, which stays
    # the fallback.
    # ----------------------------------------------------------------------
    Info "Unpacking into $Prefix"
    New-Item -ItemType Directory -Path $Prefix -Force | Out-Null

    $unpackDir = Join-Path $Prefix (".unpack-$PID-" + [Guid]::NewGuid().ToString('N'))
    New-Item -ItemType Directory -Path $unpackDir | Out-Null
    if (Get-Command tar -ErrorAction SilentlyContinue) {
        & tar -xf $pkg -C $unpackDir
        if ($LASTEXITCODE -ne 0) { Die "tar failed to unpack $($best.Name)" }
    } else {
        Expand-Archive -LiteralPath $pkg -DestinationPath $unpackDir
    }

    $topDirs = @(Get-ChildItem -LiteralPath $unpackDir -Directory -Force)
    if ($topDirs.Count -ne 1) { Die "unexpected package layout in $($best.Name)" }
    $topDir = $topDirs[0].Name
    $unpacked = $topDirs[0].FullName

    # Falls back to the directory the package actually carried, so an
    # unrecognised name costs the tidy layout rather than the install.
    $Version = $topDir
    if ($topDir -match '^mariadb-restd-([0-9][0-9.]*)-') { $Version = $Matches[1] }

    # ----------------------------------------------------------------------
    # The install lock. Several installers can run into one prefix at once
    # (several agent sessions each install what they need), so every step that
    # changes what they share -- the version folders, the shims, the prune --
    # runs under a named mutex. Everything before it runs in parallel. Windows
    # releases the mutex of a process that dies, and the next waiter gets it as
    # abandoned, so a killed install blocks nothing.
    #
    # The name is a hash of the prefix, so installs into different prefixes do
    # not wait on each other. Global\ so that sessions of one user (desktop,
    # SSH) see each other; Local\ when a prefix shared between users already
    # has a mutex this user may not open.
    # ----------------------------------------------------------------------
    $sha = [Security.Cryptography.SHA256]::Create()
    $prefixHash = -join ($sha.ComputeHash([Text.Encoding]::UTF8.GetBytes($prefixFull.ToLowerInvariant())) |
        Select-Object -First 8 | ForEach-Object { $_.ToString('x2') })
    $sha.Dispose()
    try {
        $installMutex = [System.Threading.Mutex]::new($false, "Global\mariadb-restd-install-$prefixHash")
    } catch [UnauthorizedAccessException] {
        $installMutex = [System.Threading.Mutex]::new($false, "Local\mariadb-restd-install-$prefixHash")
    }
    $lockTimeout = [TimeSpan]::FromSeconds(300)
    try {
        $haveMutex = $installMutex.WaitOne(0)
        if (-not $haveMutex) {
            [Console]::Error.WriteLine("install.ps1: waiting for another install into $Prefix to finish")
            $haveMutex = $installMutex.WaitOne($lockTimeout)
        }
    } catch [Threading.AbandonedMutexException] {
        # Its holder died without releasing it; the mutex is now ours.
        $haveMutex = $true
    }
    if (-not $haveMutex) {
        Die "gave up after $([int]$lockTimeout.TotalSeconds)s waiting for another install into $Prefix.
  Close any other running install and try again."
    }

    # Deletes a version folder unless a program runs from it. Windows lets a
    # folder be renamed, and every file not mapped into a process be deleted,
    # while a program runs from it -- which would leave a running daemon
    # without the plugins it has not loaded yet -- so a folder in use is left
    # whole. The folder is moved aside first, so a deletion that stops part way
    # leaves a .remove-* folder for a later run to clear rather than a broken
    # version. Returns whether it is gone (or at least out of the way).
    function Test-DirInUse([string] $Dir) {
        $root = $Dir.TrimEnd('\') + '\'
        [bool] (Get-Process -ErrorAction SilentlyContinue | Where-Object {
            $_.Path -and $_.Path.StartsWith($root, [StringComparison]::OrdinalIgnoreCase)
        } | Select-Object -First 1)
    }
    function Remove-VersionDir([string] $Dir) {
        if (Test-DirInUse $Dir) { return $false }
        $aside = Join-Path $Prefix (".remove-" + [Guid]::NewGuid().ToString('N'))
        try {
            Move-Item -LiteralPath $Dir -Destination $aside -ErrorAction Stop
        } catch {
            return $false
        }
        Remove-Item -LiteralPath $aside -Recurse -Force -ErrorAction SilentlyContinue
        return $true
    }

    # Folders of runs that were killed, which no finally removed: unpack
    # folders whose process is gone, and folders set aside for removal.
    Get-ChildItem -LiteralPath $Prefix -Directory -Force -ErrorAction SilentlyContinue |
        Where-Object { $_.FullName -ne $unpackDir } | ForEach-Object {
            if ($_.Name -match '^\.unpack-(\d+)-') {
                if (Get-Process -Id ([int]$Matches[1]) -ErrorAction SilentlyContinue) { return }
            } elseif ($_.Name -notmatch '^\.remove-') {
                return
            }
            if (Test-DirInUse $_.FullName) { return }
            Remove-Item -LiteralPath $_.FullName -Recurse -Force -ErrorAction SilentlyContinue
        }

    # A version folder whose mariadb-restd.exe is byte for byte the one just
    # unpacked holds the same build -- typically because another installer
    # finished it a moment ago -- and is kept, with only the shims rewritten:
    # Windows cannot replace a program that is running, and a daemon may be
    # running from it. Any other folder of that name is replaced.
    $target = Join-Path $Prefix $Version
    $restdExe = Join-Path (Join-Path $target 'bin') 'mariadb-restd.exe'
    $newExe = Join-Path (Join-Path $unpacked 'bin') 'mariadb-restd.exe'
    if ((Test-Path -LiteralPath $restdExe) -and (Test-Path -LiteralPath $newExe) -and
        ((Get-FileHash -LiteralPath $restdExe -Algorithm SHA256).Hash -eq
         (Get-FileHash -LiteralPath $newExe -Algorithm SHA256).Hash)) {
        Info "Keeping $target, already installed from this build"
    } else {
        if ((Test-Path -LiteralPath $target) -and -not (Remove-VersionDir $target)) {
            Die "could not replace ${target}: a program is running from it.
  Stop every mariadb-restd started from it, then run the install again."
        }
        Move-Item -LiteralPath $unpacked -Destination $target
    }

    if (-not (Test-Path $restdExe)) { Die "no mariadb-restd.exe at $restdExe after unpacking" }

    # ----------------------------------------------------------------------
    # Shims. A symlink on Windows needs privileges this script cannot assume, so
    # the stable names are .cmd forwarders instead. With the bin directory
    # inside the prefix (the default), they are written relative to their own
    # location (%~dp0), so moving the whole prefix does not break them. A bin
    # directory elsewhere (-BinDir / MARIADB_RESTD_BINDIR) has no such relative
    # path to the version directory, so there they name the exe by its absolute
    # path.
    #
    # A program this package lacks loses the shim an earlier install left: it
    # would start that version, or nothing once the prune below removes it.
    # Only a shim of ours is removed: one that forwards into a version
    # directory, relative or under this prefix.
    # ----------------------------------------------------------------------
    New-Item -ItemType Directory -Path $BinDir -Force | Out-Null
    $shims = @()
    foreach ($prog in $Programs) {
        $exe = Join-Path (Join-Path $target 'bin') "$prog.exe"
        $shim = Join-Path $BinDir "$prog.cmd"
        if (Test-Path -LiteralPath $exe) {
            Set-Content -Path $shim -NoNewline -Encoding ascii `
                -Value "@echo off`r`n`"$versionRoot\$Version\bin\$prog.exe`" %*`r`n"
            $shims += $shim
        } elseif ((Test-Path -LiteralPath $shim) -and
                  ((Get-Content -Raw -LiteralPath $shim) -match
                    ('"(' + [regex]::Escape($relativeDir) + '|' + [regex]::Escape($absoluteDir) +
                     ')\\[0-9][0-9.]*\\bin\\' + [regex]::Escape($prog) + '\.exe"'))) {
            Remove-Item -Force -LiteralPath $shim
        }
    }

    $reported = $Version
    try {
        $reported = @(& $restdExe --version 2>$null)[0]
        if (-not $reported) { $reported = $Version }
    } catch {
        # A machine mid-upgrade, or one missing what the package needs: the
        # install is still sound, so this is a nicety, not a failure.
    }

    Info "Installed $reported"
    $label = 'Commands:'
    foreach ($shim in $shims) {
        Info "$label $shim"
        $label = '         '
    }

    # ----------------------------------------------------------------------
    # Prune. Only the version just installed and the highest of the rest
    # survive: one way back is worth keeping, a museum is not. Deliberately
    # narrow about what it will delete -- a name has to be purely digits and
    # dots to be considered ours, so anything else under the prefix is left
    # alone rather than guessed at. That includes this script's own .unpack-*
    # and .remove-* folders. A version still in use cannot be removed on
    # Windows; that costs a warning, not the install, and a later install
    # removes it.
    # ----------------------------------------------------------------------
    function ConvertTo-SortableVersion([string] $Name) {
        try { return [version] $Name } catch { return $null }
    }

    $versionDirs = Get-ChildItem -Path $Prefix -Directory -ErrorAction SilentlyContinue |
        Where-Object { $_.Name -match '^[0-9][0-9.]*$' -and $_.Name -ne $Version -and
                       $null -ne (ConvertTo-SortableVersion $_.Name) }

    $keepOther = $versionDirs |
        Sort-Object -Property @{ Expression = { ConvertTo-SortableVersion $_.Name } } |
        Select-Object -Last 1

    foreach ($d in $versionDirs) {
        if ($keepOther -and $d.Name -eq $keepOther.Name) { continue }
        Info "Removing superseded version $($d.Name)"
        if (-not (Remove-VersionDir $d.FullName)) {
            [Console]::Error.WriteLine("install.ps1: warning: could not remove $($d.FullName), a program is running from it; a later install removes it")
        }
    }
    if ($keepOther) { Info "Kept previous version $($keepOther.Name)" }

    $installMutex.ReleaseMutex()
    $haveMutex = $false

    # ----------------------------------------------------------------------
    # PATH. Edited only when asked: rewriting a user's environment from a piped
    # installer is not this script's call to make, which is the same line
    # install.sh draws at a user's shell rc.
    # ----------------------------------------------------------------------
    $userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
    $onPath = $userPath -and (($userPath -split ';') -contains $BinDir)

    if ($AddToPath) {
        if ($onPath) {
            Info "$BinDir is already on your PATH"
        } else {
            $updated = if ($userPath) { "$userPath;$BinDir" } else { $BinDir }
            [Environment]::SetEnvironmentVariable('Path', $updated, 'User')
            Info "Added $BinDir to your user PATH (open a new terminal to pick it up)"
        }
    } elseif (-not $onPath) {
        Write-Host ""
        Write-Host "$BinDir is not on your PATH. Add it with:"
        Write-Host ""
        Write-Host "    [Environment]::SetEnvironmentVariable('Path', ([Environment]::GetEnvironmentVariable('Path','User') + ';$BinDir'), 'User')"
        Write-Host ""
        Write-Host "or re-run this installer with -AddToPath."
        Write-Host ""
    }
} finally {
    if ($unpackDir) { Remove-Item -LiteralPath $unpackDir -Recurse -Force -ErrorAction SilentlyContinue }
    if ($haveMutex) { $installMutex.ReleaseMutex() }
    if ($installMutex) { $installMutex.Dispose() }
    Remove-Item -Recurse -Force $Tmp -ErrorAction SilentlyContinue
}
