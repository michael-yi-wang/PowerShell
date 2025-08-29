
<#
.SYNOPSIS
	Check installed PowerShell modules and report which are outdated. Optionally remove older installed versions.

.DESCRIPTION
	The script enumerates installed modules (via PowerShellGet when available), queries the gallery for the latest
	published version and lists modules where the installed highest version is older than the latest available.

	When called with -DeleteConfirm the script will attempt to uninstall any installed versions that are older
	than the latest available version.

.PARAMETER DeleteConfirm
	When provided, the script will remove outdated module versions it finds (no additional prompt).

.EXAMPLE
	.\Check-OutdatedModule.ps1
	Lists outdated modules.

.EXAMPLE
	.\Check-OutdatedModule.ps1 -DeleteConfirm
	Lists outdated modules and removes older installed versions.

#>

[CmdletBinding()]
param(
	[switch]
	$DeleteConfirm
)

function Get-LatestModuleVersion {
	param(
		[Parameter(Mandatory=$true)]
		[string]$Name
	)

	try {
		# Try to find module in registered repositories (requires internet access and registered repo like PSGallery)
		$found = Find-Module -Name $Name -ErrorAction Stop
		return $found.Version
	}
	catch {
		# Not found or offline
		return $null
	}
}

Write-Verbose "Enumerating installed modules..."

# Prefer Get-InstalledModule (modules installed via PowerShellGet). If not available/empty, fall back to Get-Module -ListAvailable
$installedModules = @()
try {
	$installedModules = Get-InstalledModule -AllVersions -ErrorAction SilentlyContinue
}
catch {
	$installedModules = @()
}

if (-not $installedModules -or $installedModules.Count -eq 0) {
	Write-Verbose "No entries from Get-InstalledModule; falling back to Get-Module -ListAvailable (these may not be removable with Uninstall-Module)."
	$modulesRaw = Get-Module -ListAvailable | Where-Object { $_.Name -and $_.Version } | Sort-Object Name, Version -Descending
	# Build objects compatible with Get-InstalledModule shape
	$installedModules = $modulesRaw | ForEach-Object {
		[PSCustomObject]@{
			Name = $_.Name
			Version = $_.Version
		}
	}
}

# Group by module name and determine highest installed version and all versions
$grouped = $installedModules | Group-Object -Property Name

$report = @()

foreach ($g in $grouped) {
	$name = $g.Name
	$versions = ($g.Group | Select-Object -ExpandProperty Version | ForEach-Object { [version]$_ }) | Sort-Object -Descending
	$highestInstalled = $versions[0]
	$installedVersionsText = ($versions | ForEach-Object { $_.ToString() }) -join ", "

	$latest = Get-LatestModuleVersion -Name $name
	$isOutdated = $false
	if ($latest) {
		try {
			if ([version]$latest -gt [version]$highestInstalled) { $isOutdated = $true }
		}
		catch {
			# Comparison failed; treat as not found/outdated unknown
			$isOutdated = $false
		}
	}

	$report += [PSCustomObject]@{
		Name = $name
		InstalledVersions = $installedVersionsText
		HighestInstalledVersion = $highestInstalled.ToString()
		LatestAvailableVersion = if ($latest) { $latest.ToString() } else { $null }
		IsOutdated = $isOutdated
	}
}

$outdated = $report | Where-Object { $_.IsOutdated -eq $true } | Sort-Object Name

if ($outdated.Count -eq 0) {
	Write-Output "No outdated modules were detected."
	return
}

Write-Output "Outdated modules found:`n"
$outdated | Select-Object Name, InstalledVersions, HighestInstalledVersion, LatestAvailableVersion | Format-Table -AutoSize

if ($DeleteConfirm) {
	Write-Output "`n-DeleteConfirm specified: attempting to remove older installed versions of the outdated modules..."

	foreach ($m in $outdated) {
		$name = $m.Name
		$latestVer = $m.LatestAvailableVersion

		# Find installed module objects matching name and with version < latest
		$installedForName = $installedModules | Where-Object { $_.Name -eq $name }
		$toRemove = $installedForName | Where-Object { 
			try { [version]$_.Version -lt [version]$latestVer } catch { $false }
		}

		if (-not $toRemove -or $toRemove.Count -eq 0) {
			Write-Output "No removable older versions found for $name"
			continue
		}

		foreach ($inst in $toRemove) {
			$ver = $inst.Version.ToString()
			Write-Output "Removing $name version $ver ..."
			try {
				# Attempt to uninstall the specific older version
				Uninstall-Module -Name $name -RequiredVersion $ver -Force -ErrorAction Stop
				Write-Output "Removed $name $ver"
			}
			catch {
				Write-Warning ("Failed to remove {0} {1}: {2}" -f $name, $ver, $_.Exception.Message)
			}
		}
	}

	Write-Output "Removal step complete."
}
else {
	Write-Output "To remove outdated versions, re-run this script with the -DeleteConfirm switch."
}
