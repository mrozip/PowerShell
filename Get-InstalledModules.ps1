<#
.SYNOPSIS
    Shows the PowerShell version, lists installed modules with their latest PSGallery
    version (red = update available, green = up to date) and offers to update them.

.PARAMETER Repository
    Repository to check for newer versions. Defaults to PSGallery.

.EXAMPLE
    .\Get-ModuleUpdateStatus.ps1
#>
[CmdletBinding()]
param(
    [string]$Repository = 'PSGallery'
)

function ConvertTo-ComparableVersion {
    param([string]$Version)
    # Strip prerelease/build suffixes so [version] can parse it
    if ($Version -match '^\d+(\.\d+){0,3}') { return [version]($Matches[0] -replace '^(\d+)$', '$1.0') }
    return [version]'0.0'
}

$docs = [Environment]::GetFolderPath('MyDocuments')
$userRoots = @(
    if ($docs) { Join-Path $docs 'WindowsPowerShell\Modules'; Join-Path $docs 'PowerShell\Modules' }
    Join-Path $HOME '.local/share/powershell/Modules'
)
$allUsersRoots = @(
    if ($env:ProgramFiles) { Join-Path $env:ProgramFiles 'WindowsPowerShell\Modules'; Join-Path $env:ProgramFiles 'PowerShell\Modules' }
    '/usr/local/share/powershell/Modules'
)
$systemRoots = @(
    Join-Path $PSHOME 'Modules'
    if ($env:windir) { Join-Path $env:windir 'System32\WindowsPowerShell\v1.0\Modules' }
)

function Get-ModuleScope {
    param([string]$Path)
    $test = { param($roots) foreach ($r in $roots) { if ($Path.StartsWith($r.TrimEnd('\', '/') + [IO.Path]::DirectorySeparatorChar, [StringComparison]::OrdinalIgnoreCase)) { return $true } } }
    if (& $test $systemRoots) { return 'System' }
    if (& $test $userRoots) { return 'CurrentUser' }
    if (& $test $allUsersRoots) { return 'AllUsers' }
    # Non-standard locations (e.g. MSI-installed modules). Anything outside the user profile is machine-wide
    if (& $test @($HOME)) { return 'CurrentUser' }
    return 'AllUsers'
}

$isWin = $PSVersionTable.PSVersion.Major -lt 6 -or $IsWindows
$isAdmin = if ($isWin) {
    ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}
else { (id -u) -eq '0' }

# PS 5.1 defaults to older TLS versions, which PSGallery rejects
if ($PSVersionTable.PSVersion.Major -lt 6) {
    [Net.ServicePointManager]::SecurityProtocol = [Net.ServicePointManager]::SecurityProtocol -bor [Net.SecurityProtocolType]::Tls12
}

# PowerShell version
$psv = $PSVersionTable.PSVersion
$edition = if ($PSVersionTable.PSEdition) { $PSVersionTable.PSEdition } else { 'Desktop' }
$psName = if ($psv.Major -ge 6) { 'PowerShell' } else { 'Windows PowerShell' }
Write-Host ''
Write-Host ("Running {0} {1}" -f $psName, $psv) -ForegroundColor Cyan -NoNewline
if ($isAdmin) { Write-Host ' [Admin]' -ForegroundColor Red -NoNewline }
Write-Host (" ({0} edition)" -f $edition) -ForegroundColor Cyan
Write-Host ''

# Gather installed modules (highest version of each)
Write-Host 'Collecting installed modules...' -ForegroundColor DarkGray
$installed = Get-Module -ListAvailable |
    Group-Object Name |
    ForEach-Object { $_.Group | Sort-Object Version -Descending | Select-Object -First 1 } |
    Sort-Object Name

Write-Host ("Checking {0} for {1} modules (this may take a moment)..." -f $Repository, $installed.Count) -ForegroundColor DarkGray
$latestLookup = @{}
$names = @($installed.Name)
$batchSize = 25 # Large single queries to the gallery silently return nothing, so query in batches
for ($i = 0; $i -lt $names.Count; $i += $batchSize) {
    $batch = $names[$i..([Math]::Min($i + $batchSize, $names.Count) - 1)]
    Find-Module -Name $batch -Repository $Repository -ErrorAction SilentlyContinue |
        ForEach-Object { $latestLookup[$_.Name] = [string]$_.Version }
}

$results = foreach ($m in $installed) {
    $latest = $latestLookup[$m.Name]
    [pscustomobject]@{
        Name             = $m.Name
        Scope            = Get-ModuleScope $m.ModuleBase
        InstalledVersion = [string]$m.Version
        LatestVersion    = if ($latest) { $latest } else { 'N/A' }
        UpdateAvailable  = [bool]($latest -and (ConvertTo-ComparableVersion $latest) -gt (ConvertTo-ComparableVersion $m.Version))
    }
}

# Coloured table
$h = 'Name', 'Scope', 'Installed Version', 'Latest Version'
$w1 = [Math]::Max($h[0].Length, ($results.Name | Measure-Object Length -Maximum).Maximum) + 2
$w2 = [Math]::Max($h[1].Length, ($results.Scope | Measure-Object Length -Maximum).Maximum) + 2
$w3 = [Math]::Max($h[2].Length, ($results.InstalledVersion | Measure-Object Length -Maximum).Maximum) + 2
$w4 = [Math]::Max($h[3].Length, ($results.LatestVersion | Measure-Object Length -Maximum).Maximum)

Write-Host ''
Write-Host ($h[0].PadRight($w1) + $h[1].PadRight($w2) + $h[2].PadRight($w3) + $h[3]) -ForegroundColor White
Write-Host (('-' * ($w1 - 2)).PadRight($w1) + ('-' * ($w2 - 2)).PadRight($w2) + ('-' * ($w3 - 2)).PadRight($w3) + ('-' * $w4)) -ForegroundColor White
foreach ($r in $results) {
    $colour = if ($r.UpdateAvailable) { 'Red' } else { 'Green' }
    Write-Host ($r.Name.PadRight($w1) + $r.Scope.PadRight($w2) + $r.InstalledVersion.PadRight($w3) + $r.LatestVersion) -ForegroundColor $colour
}
Write-Host ''
Write-Host 'Scope: CurrentUser = your profile only, AllUsers = machine-wide, System = shipped with Windows/PowerShell' -ForegroundColor DarkGray

# Offer to update
$outdated = @($results | Where-Object UpdateAvailable)
Write-Host ''
if ($outdated.Count -eq 0) {
    Write-Host 'All modules are up to date.' -ForegroundColor Green
    return
}

Write-Host ("{0} module(s) have updates available." -f $outdated.Count) -ForegroundColor Yellow
$machineWide = @($outdated | Where-Object Scope -eq 'AllUsers')
if ($machineWide.Count -gt 0 -and -not $isAdmin) {
    Write-Host ("{0} of these are machine-wide (AllUsers) and will be skipped unless run as Administrator." -f $machineWide.Count) -ForegroundColor Yellow
}
$answer = Read-Host 'Update all out-of-date modules now? (y/N)'
if ($answer -notmatch '^(y|yes)$') {
    Write-Host 'No modules were updated.' -ForegroundColor DarkGray
    return
}

foreach ($m in $outdated) {
    if ($m.Scope -eq 'AllUsers' -and -not $isAdmin) {
        Write-Host ("Skipping {0} (machine-wide install, requires Administrator)." -f $m.Name) -ForegroundColor Yellow
        continue
    }
    Write-Host ("Updating {0} [{1}] {2} -> {3}..." -f $m.Name, $m.Scope, $m.InstalledVersion, $m.LatestVersion) -ForegroundColor Cyan
    try {
        if (Get-InstalledModule -Name $m.Name -ErrorAction SilentlyContinue) {
            # Installed via PowerShellGet, so Update-Module can manage it
            Update-Module -Name $m.Name -Force -ErrorAction Stop
        }
        else {
            # Shipped with Windows/PowerShell or copied manually: install the new version side by side
            $installScope = if ($m.Scope -eq 'AllUsers') { 'AllUsers' } else { 'CurrentUser' }
            Install-Module -Name $m.Name -Repository $Repository -Scope $installScope -Force -AllowClobber -ErrorAction Stop
        }
        Write-Host ("  {0} updated." -f $m.Name) -ForegroundColor Green
    }
    catch {
        Write-Host ("  Failed to update {0}: {1}" -f $m.Name, $_.Exception.Message) -ForegroundColor Red
    }
}
