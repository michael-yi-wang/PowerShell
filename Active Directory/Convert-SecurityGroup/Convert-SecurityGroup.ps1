<#
.SYNOPSIS
    Convert security group scope(s) in Active Directory based on a CSV input.

.DESCRIPTION
    Reads a CSV of groups, collects current scope and parent-group information,
    validates scope compatibility (for example: a Global group cannot contain a
    Universal group), prompts the user for confirmation, then converts the
    group's scope using Set-ADGroup. All actions and errors are logged to a
    timestamped .log file in the CSV folder.

.PARAMETER TargetGroupScope
    The desired target group scope. Valid values: Global, Universal, DomainLocal

.PARAMETER CsvPath
    Path to a CSV file with a list of groups. The CSV must contain at least one
    of these column names: Group, Name, SamAccountName, DistinguishedName

.PARAMETER WhatIf
    Performs a dry-run (passes -WhatIf to Set-ADGroup).

.EXAMPLE
    .\Convert-SecurityGroup.ps1 -TargetGroupScope Universal -CsvPath .\groups.csv

.NOTES
    Requires the ActiveDirectory PowerShell module and appropriate AD privileges.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateSet('Global','Universal','DomainLocal')]
    [string]$TargetGroupScope,

    [Parameter(Mandatory = $true)]
    [string]$CsvPath,

    [switch]$WhatIf,

    [Parameter(Mandatory = $false)]
    [string]$DomainController
)

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $line = "[$timestamp] [$Level] $Message"
    if ($Global:LogPath) {
        try {
            Add-Content -Path $Global:LogPath -Value $line -ErrorAction Stop
        } catch {
            # If logging to file fails, still write to host
            Write-Host "Failed to write to log file: $_" -ForegroundColor Yellow
        }
    }
    Write-Host $line
}

# Remote vs local AD execution
$UseRemote = $false
$ADSession = $null
if ($PSBoundParameters.ContainsKey('DomainController') -and -not [string]::IsNullOrWhiteSpace($DomainController)) {
    try {
        Write-Log "Creating remote session to domain controller: $DomainController"
        # Prompt for credentials to use for the remote session
        try {
            $cred = Get-Credential -Message "Enter credentials to create PSSession to $DomainController"
        } catch {
            Write-Log -Message "Credential prompt cancelled or failed" -Level 'ERROR'
            return
        }

        if (-not $cred) {
            Write-Log -Message "No credentials provided; aborting remote session creation" -Level 'ERROR'
            return
        }

        $ADSession = New-PSSession -ComputerName $DomainController -Credential $cred -ErrorAction Stop
        # Import module on remote side (ensures AD cmdlets available)
        Invoke-Command -Session $ADSession -ScriptBlock { Import-Module ActiveDirectory -ErrorAction Stop } -ErrorAction Stop
        $UseRemote = $true
    } catch {
        $errMsg = ("Failed to create remote session to {0}: {1}" -f $DomainController, $_)
        Write-Log -Message $errMsg -Level 'ERROR'
        return
    }
} else {
    try {
        Import-Module ActiveDirectory -ErrorAction Stop
    } catch {
        Write-Error "ActiveDirectory module is required but could not be imported: $_"
        return
    }
}

# Helper wrappers for AD operations (use remote session when requested)
function Get-ADGroupEx {
    param(
        [Parameter(Mandatory=$true)] $Identity,
        [Parameter(Mandatory=$false)] $Properties = @()
    )
    if ($UseRemote) {
        return Invoke-Command -Session $ADSession -ScriptBlock {
            param($id,$props)
            Import-Module ActiveDirectory -ErrorAction Stop
            if ($props -and $props.Length -gt 0) {
                Get-ADGroup -Identity $id -Properties $props -ErrorAction Stop
            } else {
                Get-ADGroup -Identity $id -ErrorAction Stop
            }
        } -ArgumentList $Identity,$Properties -ErrorAction Stop
    } else {
        if ($Properties -and $Properties.Length -gt 0) {
            return Get-ADGroup -Identity $Identity -Properties $Properties -ErrorAction Stop
        } else {
            return Get-ADGroup -Identity $Identity -ErrorAction Stop
        }
    }
}

function Get-ADPrincipalGroupMembershipEx {
    param([Parameter(Mandatory=$true)] $Identity)
    if ($UseRemote) {
        return Invoke-Command -Session $ADSession -ScriptBlock {
            param($id)
            Import-Module ActiveDirectory -ErrorAction Stop
            Get-ADPrincipalGroupMembership -Identity $id -ErrorAction Stop
        } -ArgumentList $Identity -ErrorAction Stop
    } else {
        return Get-ADPrincipalGroupMembership -Identity $Identity -ErrorAction Stop
    }
}

function Set-ADGroupEx {
    param(
        [Parameter(Mandatory=$true)] $Identity,
        [Parameter(Mandatory=$true)] $GroupScope,
        [switch]$WhatIfLocal
    )
    if ($UseRemote) {
        $sb = {
            param($id,$scope,$whatif)
            Import-Module ActiveDirectory -ErrorAction Stop
            if ($whatif) {
                Set-ADGroup -Identity $id -GroupScope $scope -WhatIf
            } else {
                Set-ADGroup -Identity $id -GroupScope $scope -ErrorAction Stop
            }
        }
        return Invoke-Command -Session $ADSession -ScriptBlock $sb -ArgumentList $Identity,$GroupScope,($WhatIfLocal.IsPresent) -ErrorAction Stop
    } else {
        if ($WhatIfLocal) {
            Set-ADGroup -Identity $Identity -GroupScope $GroupScope -WhatIf
        } else {
            Set-ADGroup -Identity $Identity -GroupScope $GroupScope -ErrorAction Stop
        }
    }
}

if (-not (Test-Path -Path $CsvPath)) {
    Write-Error "CSV file not found: $CsvPath"
    return
}

$CsvFull = (Resolve-Path -Path $CsvPath).ProviderPath
$CsvFolder = Split-Path -Parent $CsvFull
$LogPath = Join-Path $CsvFolder ("Convert-SecurityGroup_{0:yyyyMMdd_HHmmss}.log" -f (Get-Date))

Write-Log "Script started. CSV: $CsvFull. Target scope: $TargetGroupScope"

try {
    $csv = Import-Csv -Path $CsvFull -ErrorAction Stop
} catch {
    Write-Error "Failed to import CSV: $_"
    return
}

if ($csv.Count -eq 0) {
    Write-Error "CSV contains no rows."
    return
}

# Detect column that contains group identity
$possibleCols = 'Group','Name','SamAccountName','DistinguishedName','sAMAccountName'
$col = $null
foreach ($c in $possibleCols) {
    if ($csv | Get-Member -Name $c -MemberType NoteProperty -ErrorAction SilentlyContinue) {
        $col = $c; break
    }
}

if (-not $col) {
    Write-Error "CSV must contain a column named one of: $($possibleCols -join ', ')"
    return
}

Write-Log "Using CSV column '$col' as group identity. Rows: $($csv.Count)"

$workItems = @()

foreach ($row in $csv) {
    $identity = $row.$col
    if ([string]::IsNullOrWhiteSpace($identity)) {
        Write-Log "Skipping empty identity row" "WARN"
        continue
    }

    try {
        $g = Get-ADGroup -Identity $identity -Properties GroupScope,GroupCategory,DistinguishedName,Name,sAMAccountName -ErrorAction Stop
    } catch {
        Write-Log "Group not found: $identity" "ERROR"
        $workItems += [PSCustomObject]@{
            InputIdentity = $identity
            Found = $false
            Reason = 'NotFound'
        }
        continue
    }

    $parents = @()
    try {
        $parentGroups = Get-ADPrincipalGroupMembership -Identity $g.DistinguishedName -ErrorAction Stop
        foreach ($p in $parentGroups) {
            # Ensure GroupScope property is available
            $pFull = Get-ADGroup -Identity $p.DistinguishedName -Properties GroupScope -ErrorAction SilentlyContinue
            $parents += [PSCustomObject]@{
                Name = $p.Name
                SamAccountName = $p.sAMAccountName
                DistinguishedName = $p.DistinguishedName
                GroupScope = if ($pFull) { $pFull.GroupScope } else { 'Unknown' }
            }
        }
    } catch {
        Write-Log "Failed to enumerate parent groups for $($g.Name): $_" "WARN"
    }

    $needsChange = ($g.GroupScope -ne $TargetGroupScope)

    # Detect potential parent-scope conflicts: parent scope is Global while target is Universal
    $parentConflicts = @()
    foreach ($pg in $parents) {
        if (($pg.GroupScope -eq 'Global') -and ($TargetGroupScope -eq 'Universal')) {
            $parentConflicts += $pg
        }
    }

    $workItems += [PSCustomObject]@{
        InputIdentity = $identity
        Found = $true
        Name = $g.Name
        SamAccountName = $g.sAMAccountName
        DistinguishedName = $g.DistinguishedName
        CurrentScope = $g.GroupScope
        TargetScope = $TargetGroupScope
        NeedsChange = $needsChange
        ParentGroups = $parents
        ParentConflicts = $parentConflicts
    }
}

# Present gathered info and pending changes
Write-Host "\nSummary of groups and pending actions:`n" -ForegroundColor Cyan

$toChange = $workItems | Where-Object { $_.Found -and $_.NeedsChange }
$skipped = $workItems | Where-Object { -not $_.Found -or -not $_.NeedsChange }

Write-Host "Groups found: $($workItems | Where-Object { $_.Found } | Measure-Object).Count"
Write-Host "Groups to change: $($toChange.Count)"
Write-Host "Groups skipped or not found: $($skipped.Count)\n"

if ($toChange.Count -gt 0) {
    Write-Host "Pending conversions:" -ForegroundColor Yellow
    $toChange | ForEach-Object {
        $conflictText = if ($_.ParentConflicts.Count -gt 0) { "CONFLICT: Parent(s) with Global scope: $($_.ParentConflicts | ForEach-Object { $_.Name } -join ', ')" } else { '' }
        Write-Host ("- {0}  (current: {1} -> target: {2}) {3}" -f $_.Name, $_.CurrentScope, $_.TargetScope, $conflictText)
    }
    Write-Host "`nLog file: $LogPath`n"

    # Ask how to proceed when conflicts exist
    $hasConflicts = ($toChange | Where-Object { $_.ParentConflicts.Count -gt 0 }).Count -gt 0

    $globalChoice = $null
    if ($hasConflicts) {
        Write-Host "One or more groups have parent-scope conflicts (Global parent cannot contain Universal member)." -ForegroundColor Red
        Write-Host "Choose how to proceed:`n  [A]bort - cancel everything`n  [P]rompt - prompt per conflicting group`n  [C]ontinue - attempt all conversions regardless of conflicts`n"
        while ($true) {
            $globalChoice = Read-Host "Enter choice (A/P/C)"
            switch ($globalChoice.ToUpper()) {
                'A' { Write-Log 'User aborted due to parent-scope conflicts'; return }
                'P' { break }
                'C' { break }
                default { Write-Host 'Invalid choice, enter A, P, or C' }
            }
        }
    } else {
        # simple yes/no confirmation
        $yn = Read-Host "Proceed with all listed conversions? (Y/N)"
        if ($yn.ToUpper() -ne 'Y') { Write-Log 'User aborted before conversion'; return }
    }

    # Final per-item decisions if prompting
    $finalList = @()
    foreach ($item in $toChange) {
        $proceed = $true
        if ($globalChoice -eq 'P' -and $item.ParentConflicts.Count -gt 0) {
            Write-Host "Group: $($item.Name) has parent(s) with Global scope: $($item.ParentConflicts | ForEach-Object { $_.Name } -join ', ')" -ForegroundColor Magenta
            $r = Read-Host "Convert $($item.Name) to $($item.TargetScope) anyway? (Y/N)"
            if ($r.ToUpper() -ne 'Y') { $proceed = $false; Write-Log "User chose to skip conversion for $($item.Name) due to conflict" }
        }
        $finalList += [PSCustomObject]@{
            Item = $item
            Proceed = $proceed
        }
    }

    # Execute conversions
    foreach ($entry in $finalList) {
        $it = $entry.Item
        if (-not $entry.Proceed) { continue }

        Write-Log "Attempting conversion: $($it.Name) from $($it.CurrentScope) -> $($it.TargetScope)"
        try {
            if ($WhatIf) {
                Set-ADGroup -Identity $it.DistinguishedName -GroupScope $it.TargetScope -WhatIf
                Write-Log "(WhatIf) Would set $($it.Name) -> $($it.TargetScope)"
            } else {
                Set-ADGroup -Identity $it.DistinguishedName -GroupScope $it.TargetScope -ErrorAction Stop
                Write-Log "SUCCESS: Converted $($it.Name) -> $($it.TargetScope)"
            }
        } catch {
            Write-Log "ERROR converting $($it.Name): $_" "ERROR"
        }
    }

    Write-Log "Conversion run complete"
} else {
    Write-Host "No groups require conversion to target scope. Nothing to do." -ForegroundColor Green
    Write-Log "No groups required conversion. Exiting."
}

Write-Log "Script finished."

if ($UseRemote -and $ADSession) {
    try {
        Remove-PSSession -Session $ADSession -ErrorAction Stop
        Write-Log ("Closed remote session to {0}" -f $DomainController)
    } catch {
        $errMsg = ("Failed to remove remote session: {0}" -f $_)
        Write-Log -Message $errMsg -Level 'WARN'
    }
}
