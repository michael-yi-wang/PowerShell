#Requires -Version 5.1
#Requires -Modules DnsServer

<#
.SYNOPSIS
    Removes a stale name server (NS record) belonging to a decommissioned host
    from every DNS zone on a domain controller - both zone apex NS records and
    delegation NS records - but only after proving the host no longer resolves.

.DESCRIPTION
    When a domain controller is demoted, its NS records should be removed
    automatically from every zone it served. In practice they are frequently
    left behind. A zone-root NS record pointing at a host that no longer exists
    is a broken delegation: resolvers referred to that name server wait for a
    timeout before trying the next one, which surfaces as intermittently slow
    name resolution.

    This script enumerates every forward and reverse lookup zone on the DNS
    server (excluding auto-created zones and TrustAnchors), finds each zone
    whose root NS records reference -TargetHostName, and removes those records.

    SAFETY GATE
    Because removing NS records from every zone at once is destructive and hard
    to reverse, the script refuses to remove anything unless it first proves the
    target host is genuinely gone. Before touching any zone it:

      1. Flushes the local DNS client cache, so neither a stale positive nor a
         stale negative answer can skew the test.
      2. Resolves the local computer's own FQDN as a control. If that fails the
         local resolver itself is broken, every lookup would falsely report
         ResolveFailed, and the script aborts rather than deleting NS records
         across every zone.
      3. Resolves -TargetHostName (A and AAAA) against every server in
         -ResolutionDnsServer. The resulting status must be exactly
         'ResolveFailed' - meaning no server could resolve the name at all. Any
         other status ('OK' or 'NoHostRecord') aborts the run with no changes.

    The IP address column shown in DNS Manager's Name Servers tab is NOT
    evidence either way. An NS record stores a name only; that column is a live
    lookup performed by the console when it draws the list, and it reports
    "Unknown" for reasons as benign as a cached negative answer on the
    workstation running the console. This script therefore ignores the GUI and
    performs its own resolution test.

    SCOPE - TWO PLACES NS RECORDS LIVE
    NS records referencing a host exist in two distinct places, and demotion
    cleanup commonly fixes one but not the other:

      ZoneRoot   - NS records at the zone apex ('@'), inside the zone itself.
                   These are the servers authoritative for THAT zone, and are
                   what DNS Manager's Name Servers tab shows.
      Delegation - NS records in the PARENT zone, stored at the child's node
                   (e.g. node 'west' inside zone contoso.com). These refer
                   queries for the child subtree elsewhere. In DNS Manager they
                   appear as greyed-out folders under the parent zone.

    Both are processed by default. Use -Scope to restrict to one.

    GUARD - NEVER STRIP A NODE BARE
    The script will not remove every NS record from a node, even when they all
    match -TargetHostName. At the apex that would leave a zone with no name
    servers; at a delegation node it deletes the delegation itself, making the
    entire child subtree unresolvable through that parent. Such matches are
    reported prominently, written to the CSV, and left untouched for a human to
    resolve - by adding a valid name server first, or by removing the delegation
    deliberately with Remove-DnsServerZoneDelegation.

    Glue and host (A/AAAA) records are never modified. If the stale host also
    has a host record, remove it separately after confirming nothing else
    depends on it.

    All actions and errors are logged to a timestamped .log file, and results
    are exported to a timestamped .csv file. Both are written to a 'logs'
    subfolder alongside the script, which is created on first run.

.PARAMETER TargetHostName
    The host whose NS records are to be removed, e.g. dc01.contoso.com

    A fully qualified name is matched against the full NS record data. A single
    label (e.g. 'dc01') is matched against the leftmost label of each NS record,
    which is convenient but less precise - prefer the FQDN.

.PARAMETER DnsServer
    Optional. The DNS server whose zones are read and modified. Defaults to the
    local computer name, since this script is expected to run on the domain
    controller that also hosts the DNS Server role.

.PARAMETER Scope
    Optional. Which NS records to act on. Defaults to All.

      All        - Zone apex NS records and delegation NS records (default).
      ZoneRoot   - Only NS records at the zone apex ('@'), i.e. what DNS
                   Manager's Name Servers tab shows.
      Delegation - Only NS records at delegation nodes inside a parent zone.

.PARAMETER ResolutionDnsServer
    Optional. One or more DNS servers used to test whether -TargetHostName still
    resolves. Defaults to -DnsServer. If ANY listed server resolves the name,
    the host is not stale and the script aborts without changes. Supplying
    several servers guards against a single server having a blind spot due to an
    unreplicated or scavenged host record.

.PARAMETER ExcludeZone
    Optional. One or more zone names to skip, in addition to auto-created zones
    and TrustAnchors which are always excluded.

.PARAMETER WhatIf
    Performs a dry-run: shows which NS records would be removed from which zones
    without making any changes (passed through to Remove-DnsServerResourceRecord).

.PARAMETER Force
    Skips the interactive confirmation prompt after the removal summary is
    displayed. Use for unattended runs. This does NOT bypass the resolution
    safety gate - a host that still resolves is never removed, with or without
    -Force.

.EXAMPLE
    .\Remove-StaleNS.ps1 -TargetHostName dc01.contoso.com -WhatIf

    Shows every zone that still lists dc01.contoso.com as a name server, without
    changing anything. Run this first.

.EXAMPLE
    .\Remove-StaleNS.ps1 -TargetHostName dc01.contoso.com

    Verifies dc01.contoso.com no longer resolves, lists the affected zones,
    prompts for confirmation, then removes the NS records.

.EXAMPLE
    .\Remove-StaleNS.ps1 -TargetHostName dc01.contoso.com -ResolutionDnsServer dc02.contoso.com,dc03.contoso.com -Force

    Confirms the host resolves on neither dc02 nor dc03 before removing its NS
    records from every zone, without prompting.

.EXAMPLE
    .\Remove-StaleNS.ps1 -TargetHostName dc01.contoso.com -Scope Delegation -WhatIf

    Shows only the delegation NS records (the greyed-out folders in DNS Manager)
    that still reference dc01.contoso.com, leaving zone apex records alone.

.NOTES
    Author  : Michael Wang
    Version : 1.0
    Date    : 2026-08-07
    Module  : DnsServer (Windows RSAT DNS Server Tools) and DnsClient. Both are
              Windows-only; no cross-platform equivalent exists for managing
              Windows DNS Server zone data, and the requirement to run on a
              domain controller makes Windows mandatory regardless.
    Requires: Must be run on a domain controller with the DnsServer module
              available, and appropriate DNS administrative privileges.
              Compatible with both Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TargetHostName,

    [ValidateNotNullOrEmpty()]
    [string]$DnsServer = $env:COMPUTERNAME,

    [ValidateSet('All', 'ZoneRoot', 'Delegation')]
    [string]$Scope = 'All',

    [string[]]$ResolutionDnsServer,

    [string[]]$ExcludeZone,

    [switch]$WhatIf,

    [switch]$Force
)

# ----------------------------------------------------------------------------
# Logging setup
# ----------------------------------------------------------------------------
$ScriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
$LogFolder    = Join-Path $ScriptFolder 'logs'
$Timestamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile      = Join-Path $LogFolder "Remove-StaleNS_$Timestamp.log"
$CsvOutput    = Join-Path $LogFolder "Remove-StaleNS_Results_$Timestamp.csv"

# The log folder has to exist before the first Write-Log call, so a failure here
# cannot be reported through Write-Log itself.
if (-not (Test-Path -LiteralPath $LogFolder)) {
    try {
        New-Item -Path $LogFolder -ItemType Directory -Force -ErrorAction Stop | Out-Null
    } catch {
        Write-Error "Failed to create the log folder '$LogFolder': $_"
        return
    }
}

function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $Color = switch ($Level) {
        'Info'    { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }

    $Entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $Entry -ForegroundColor $Color
    $Entry | Out-File -FilePath $LogFile -Append -Encoding utf8
}

# Default the resolution servers to the DNS server being modified.
if (-not $ResolutionDnsServer) {
    $ResolutionDnsServer = @($DnsServer)
}

Write-Log -Level Info -Message "Script started. TargetHostName: $TargetHostName. DnsServer: $DnsServer. Scope: $Scope. ResolutionDnsServer: $($ResolutionDnsServer -join ', ')"

# ----------------------------------------------------------------------------
# Step 1: Confirm this is running on a domain controller
# ----------------------------------------------------------------------------
try {
    $ComputerSystem = Get-CimInstance -ClassName Win32_ComputerSystem -ErrorAction Stop
} catch {
    Write-Log -Level Error -Message "Failed to query local computer role via CIM: $_"
    return
}

# DomainRole: 4 = Backup Domain Controller, 5 = Primary Domain Controller
if ($ComputerSystem.DomainRole -notin 4, 5) {
    Write-Log -Level Error -Message "This script must be run on a domain controller. Local DomainRole is '$($ComputerSystem.DomainRole)'. Aborting."
    return
}
Write-Log -Level Info -Message 'Confirmed script is running on a domain controller.'

# ----------------------------------------------------------------------------
# Step 2: Confirm required modules are available
# ----------------------------------------------------------------------------
foreach ($RequiredModule in 'DnsServer', 'DnsClient') {
    if (-not (Get-Module -ListAvailable -Name $RequiredModule)) {
        Write-Log -Level Error -Message "The $RequiredModule PowerShell module is not available on this machine. Install the DNS Server RSAT tools (e.g. 'Install-WindowsFeature RSAT-DNS-Server') and try again."
        return
    }
}

# ----------------------------------------------------------------------------
# Step 3: Normalize the target host name
# ----------------------------------------------------------------------------
$NormalizedTarget = $TargetHostName.TrimEnd('.')
$TargetIsFqdn     = $NormalizedTarget.Contains('.')
$TargetShortName  = $NormalizedTarget.Split('.')[0]

if (-not $TargetIsFqdn) {
    Write-Log -Level Warning -Message "'$TargetHostName' is a single label, so NS records will be matched on their leftmost label only. Supplying the FQDN is more precise."
}

# ----------------------------------------------------------------------------
# Step 4: SAFETY GATE - prove the target host no longer resolves
#
# Sub-step 4a: flush the local resolver cache so a cached answer (positive or
# negative) cannot decide the outcome.
# ----------------------------------------------------------------------------
try {
    Clear-DnsClientCache -ErrorAction Stop
    Write-Log -Level Info -Message 'Flushed local DNS client cache before resolution test.'
} catch {
    Write-Log -Level Warning -Message "Could not flush the local DNS client cache: $_. Continuing - the resolution test may use cached data."
}

# Sub-step 4b: control test. If the local computer's own FQDN cannot be
# resolved, the resolver is broken and every lookup would falsely report
# ResolveFailed. Aborting here prevents mass deletion caused by a DNS outage.
$LocalFqdn = "$($ComputerSystem.DNSHostName).$($ComputerSystem.Domain)"
$ControlResolved = $false

foreach ($Server in $ResolutionDnsServer) {
    try {
        $ControlAnswer = Resolve-DnsName -Name $LocalFqdn -Type A_AAAA -Server $Server -DnsOnly -ErrorAction Stop
        if ($ControlAnswer | Where-Object { $_.QueryType -in 'A', 'AAAA' }) {
            $ControlResolved = $true
            break
        }
    } catch {
        Write-Log -Level Warning -Message "Control lookup of '$LocalFqdn' against '$Server' failed: $_"
    }
}

if (-not $ControlResolved) {
    Write-Log -Level Error -Message "Control lookup failed: none of the resolution servers could resolve this computer's own FQDN '$LocalFqdn'. Name resolution is unhealthy, so a 'ResolveFailed' result for '$NormalizedTarget' would not be trustworthy. Aborting without changes."
    return
}
Write-Log -Level Info -Message "Control lookup succeeded - '$LocalFqdn' resolves, so the resolution test is trustworthy."

# Sub-step 4c: resolve the target. Any server that answers means the host is
# still alive and nothing may be removed.
$ResolvedAddresses = @()
$ResolutionStatus  = 'ResolveFailed'

foreach ($Server in $ResolutionDnsServer) {
    try {
        $Answer = Resolve-DnsName -Name $NormalizedTarget -Type A_AAAA -Server $Server -DnsOnly -ErrorAction Stop

        # The name exists. Distinguish an actual address from a name that
        # resolves but carries no host record (e.g. CNAME-only, or NS-only).
        $Addresses = @($Answer | Where-Object { $_.QueryType -in 'A', 'AAAA' } | ForEach-Object { $_.IPAddress })

        if ($Addresses.Count -gt 0) {
            $ResolvedAddresses += $Addresses
            $ResolutionStatus = 'OK'
            Write-Log -Level Warning -Message "'$NormalizedTarget' resolved on '$Server' to: $($Addresses -join ', ')"
        } elseif ($ResolutionStatus -ne 'OK') {
            $ResolutionStatus = 'NoHostRecord'
            Write-Log -Level Warning -Message "'$NormalizedTarget' exists in DNS on '$Server' but returned no A/AAAA record."
        }
    } catch {
        Write-Log -Level Info -Message "'$NormalizedTarget' did not resolve on '$Server' (expected for a stale host): $($_.Exception.Message)"
    }
}

if ($ResolutionStatus -ne 'ResolveFailed') {
    Write-Log -Level Error -Message "Safety gate failed. Required status 'ResolveFailed' but got '$ResolutionStatus' for '$NormalizedTarget'. The host still exists in DNS, so its NS records will NOT be removed. Aborting without changes."
    if ($ResolvedAddresses.Count -gt 0) {
        Write-Log -Level Error -Message "'$NormalizedTarget' currently resolves to: $(($ResolvedAddresses | Select-Object -Unique) -join ', '). Remove the stale host record first if this DC really was decommissioned."
    }
    if ($ResolutionStatus -eq 'NoHostRecord') {
        Write-Log -Level Error -Message "Status 'NoHostRecord' means the name exists but has no address. Investigate manually - this is not proof the host is decommissioned."
    }
    return
}
Write-Log -Level Info -Message "Safety gate passed. Status for '$NormalizedTarget' is 'ResolveFailed' on all $($ResolutionDnsServer.Count) resolution server(s). Proceeding to scan zones."

# ----------------------------------------------------------------------------
# Step 5: Enumerate all forward and reverse lookup zones
# ----------------------------------------------------------------------------
try {
    $AllZones = Get-DnsServerZone -ComputerName $DnsServer -ErrorAction Stop
} catch {
    Write-Log -Level Error -Message "Failed to retrieve DNS zones from '$DnsServer': $_"
    return
}

# TrustAnchors is a real primary forward zone (it is NOT flagged IsAutoCreated),
# so it has to be excluded by name. IsAutoCreated covers 0/127/255.in-addr.arpa.
$AlwaysExcluded = @('TrustAnchors')

$Zones = $AllZones | Where-Object {
    -not $_.IsAutoCreated -and
    $_.ZoneName -notin $AlwaysExcluded -and
    $_.ZoneName -notin $ExcludeZone
}

if (-not $Zones -or @($Zones).Count -eq 0) {
    Write-Log -Level Warning -Message 'No zones matched the specified criteria. Nothing to do.'
    return
}

$ScopeDescription = switch ($Scope) {
    'All'        { 'zone apex and delegation NS records' }
    'ZoneRoot'   { 'zone apex NS records only' }
    'Delegation' { 'delegation NS records only' }
}
Write-Log -Level Info -Message "Scanning $(@($Zones).Count) zone(s) - forward and reverse - for NS records referencing '$NormalizedTarget' ($ScopeDescription)."

# ----------------------------------------------------------------------------
# Step 6: Find every zone whose root NS records reference the target
# ----------------------------------------------------------------------------
$WorkItems  = @()
$ZoneIndex  = 0
$ZoneCount  = @($Zones).Count

foreach ($Zone in $Zones) {
    $ZoneIndex++
    $ZoneNameValue = $Zone.ZoneName
    Write-Progress -Activity 'Scanning zones for stale NS records' -Status $ZoneNameValue -PercentComplete (($ZoneIndex / $ZoneCount) * 100)

    # Secondary/Stub zone data is owned by the master and cannot be edited here;
    # Forwarder zones hold no NS records at all. Record them so the skip is
    # visible in the output rather than silently dropped.
    if ($Zone.ZoneType -ne 'Primary') {
        Write-Log -Level Info -Message "Skipping zone '$ZoneNameValue': ZoneType '$($Zone.ZoneType)' is not writable on this server."
        $WorkItems += [PSCustomObject]@{
            ZoneName            = $ZoneNameValue
            ZoneType            = $Zone.ZoneType
            IsReverseLookupZone = $Zone.IsReverseLookupZone
            RecordScope         = $null
            HostName            = $null
            NameServer          = $null
            NeedsRemoval        = $false
            SkipReason          = "ZoneType '$($Zone.ZoneType)' is not writable on this server"
        }
        continue
    }

    try {
        # No -Node here: this returns NS records from every node in the zone, so
        # both the zone-apex list ('@') and any delegation nodes are covered in
        # a single query per zone.
        $NsRecords = Get-DnsServerResourceRecord -ZoneName $ZoneNameValue -RRType Ns -ComputerName $DnsServer -ErrorAction Stop
    } catch {
        Write-Log -Level Warning -Message "Could not read NS records for zone '$ZoneNameValue': $_"
        $WorkItems += [PSCustomObject]@{
            ZoneName            = $ZoneNameValue
            ZoneType            = $Zone.ZoneType
            IsReverseLookupZone = $Zone.IsReverseLookupZone
            RecordScope         = $null
            HostName            = $null
            NameServer          = $null
            NeedsRemoval        = $false
            SkipReason          = "Failed to read NS records: $_"
        }
        continue
    }

    # Evaluate one node at a time. Grouping is what makes the "never strip a
    # node bare" guard below possible - the decision depends on how many NS
    # records share the node, not on the matching record alone.
    foreach ($NodeGroup in ($NsRecords | Group-Object -Property HostName)) {
        $NodeName = $NodeGroup.Name

        # '@' is the zone apex (the Name Servers tab). Any other node name is a
        # delegation handing the child subtree off to another set of servers.
        if ($NodeName -eq '@') {
            $RecordScope   = 'ZoneRoot'
            $NodeReference = "zone '$ZoneNameValue' apex"
        } else {
            $RecordScope   = 'Delegation'
            $NodeReference = "delegation '$NodeName' in zone '$ZoneNameValue'"
        }

        if ($Scope -ne 'All' -and $Scope -ne $RecordScope) {
            continue
        }

        $NodeMatches = @()

        foreach ($Record in $NodeGroup.Group) {
            $ComparableName = $Record.RecordData.NameServer.TrimEnd('.')

            # FQDN input matches the whole name; single-label input matches the
            # leftmost label only.
            if ($TargetIsFqdn) {
                $IsMatch = $ComparableName -eq $NormalizedTarget
            } else {
                $IsMatch = $ComparableName.Split('.')[0] -eq $TargetShortName
            }

            if ($IsMatch) {
                $NodeMatches += $Record
            }
        }

        if ($NodeMatches.Count -eq 0) {
            continue
        }

        # GUARD: never remove every NS record from a node. At the apex that
        # would leave the zone with no name servers; at a delegation node it
        # deletes the delegation itself, making the entire child subtree
        # unresolvable through this parent. Either case needs a human.
        if ($NodeMatches.Count -ge $NodeGroup.Count) {
            $GuardReason = "Refused: '$NormalizedTarget' is the only name server on this node ($($NodeGroup.Count) NS record(s) total). Removing it would delete the $(if ($RecordScope -eq 'Delegation') { 'delegation' } else { 'zone apex name server list' }). Add a valid name server first, or remove the delegation deliberately."
            Write-Log -Level Error -Message "$NodeReference - $GuardReason"

            foreach ($Record in $NodeMatches) {
                $WorkItems += [PSCustomObject]@{
                    ZoneName            = $ZoneNameValue
                    ZoneType            = $Zone.ZoneType
                    IsReverseLookupZone = $Zone.IsReverseLookupZone
                    RecordScope         = $RecordScope
                    HostName            = $Record.HostName
                    NameServer          = $Record.RecordData.NameServer
                    NeedsRemoval        = $false
                    SkipReason          = $GuardReason
                }
            }
            continue
        }

        foreach ($Record in $NodeMatches) {
            Write-Log -Level Warning -Message "$NodeReference - found stale NS record '$($Record.RecordData.NameServer)' ($($NodeGroup.Count - $NodeMatches.Count) name server(s) will remain)."
            $WorkItems += [PSCustomObject]@{
                ZoneName            = $ZoneNameValue
                ZoneType            = $Zone.ZoneType
                IsReverseLookupZone = $Zone.IsReverseLookupZone
                RecordScope         = $RecordScope
                HostName            = $Record.HostName
                NameServer          = $Record.RecordData.NameServer
                NeedsRemoval        = $true
                SkipReason          = $null
            }
        }
    }
}
Write-Progress -Activity 'Scanning zones for stale NS records' -Completed

$ToRemove = @($WorkItems | Where-Object { $_.NeedsRemoval })
$Guarded  = @($WorkItems | Where-Object { -not $_.NeedsRemoval -and $_.RecordScope })

# ----------------------------------------------------------------------------
# Step 7: Summary and confirmation
# ----------------------------------------------------------------------------
if ($ToRemove.Count -eq 0 -and $Guarded.Count -eq 0) {
    Write-Host "`nNo zone lists '$NormalizedTarget' as a name server. Nothing to do." -ForegroundColor Green
    Write-Log -Level Info -Message "No NS records referencing '$NormalizedTarget' were found. Exiting."
    return
}

if ($ToRemove.Count -gt 0) {
    Write-Host "`nRemove name server '$NormalizedTarget' from the following:`n" -ForegroundColor Cyan

    $RootItems = @($ToRemove | Where-Object { $_.RecordScope -eq 'ZoneRoot' })
    if ($RootItems.Count -gt 0) {
        Write-Host "  Zone apex (Name Servers tab):" -ForegroundColor Cyan
        $RootItems | ForEach-Object { Write-Host "    - $($_.ZoneName)" }
    }

    $DelegationItems = @($ToRemove | Where-Object { $_.RecordScope -eq 'Delegation' })
    if ($DelegationItems.Count -gt 0) {
        Write-Host "  Delegations (records stored in the parent zone):" -ForegroundColor Cyan
        $DelegationItems | ForEach-Object { Write-Host "    - $($_.ZoneName) -> node '$($_.HostName)'" }
    }
}

# Guarded items are surfaced before the prompt, not buried in the CSV - they are
# the cases most likely to need action, and they will NOT be handled here.
if ($Guarded.Count -gt 0) {
    Write-Host "`nSKIPPED - these need manual review (removing them would delete a delegation or empty a zone's name server list):`n" -ForegroundColor Yellow
    $Guarded | ForEach-Object { Write-Host "    - $($_.ZoneName) -> node '$($_.HostName)' [$($_.RecordScope)]" -ForegroundColor Yellow }
}

Write-Host "`nLog file: $LogFile`n"

if ($ToRemove.Count -eq 0) {
    Write-Log -Level Warning -Message 'Every match was blocked by the last-name-server guard. No changes to make.'
    return
}

if (-not $Force -and -not $WhatIf) {
    $Confirm = Read-Host "Proceed with $($ToRemove.Count) removal(s)? (Y/N)"
    if ($Confirm.ToUpper() -ne 'Y') {
        Write-Log -Level Info -Message 'User aborted before making any changes.'
        return
    }
}

# ----------------------------------------------------------------------------
# Step 8: Remove the stale NS records
# ----------------------------------------------------------------------------
$Results = @()

foreach ($Item in $ToRemove) {
    $Result  = 'Success'
    $Message = ''

    if ($Item.RecordScope -eq 'Delegation') {
        $NodeReference = "delegation '$($Item.HostName)' in zone '$($Item.ZoneName)'"
    } else {
        $NodeReference = "zone '$($Item.ZoneName)' apex"
    }

    try {
        # -RecordData targets this one NS record. Omitting it would delete every
        # NS record at that node, wiping the zone's entire name server list or
        # the whole delegation.
        #
        # Remove-DnsServerZoneDelegation is the purpose-built cmdlet for
        # delegation nodes, but it deletes the entire delegation when the last
        # name server goes. Removing the single resource record keeps the blast
        # radius identical for both scopes and touches no glue records.
        Remove-DnsServerResourceRecord -ZoneName $Item.ZoneName `
                                       -RRType Ns `
                                       -Name $Item.HostName `
                                       -RecordData $Item.NameServer `
                                       -ComputerName $DnsServer `
                                       -Force `
                                       -WhatIf:$WhatIf `
                                       -ErrorAction Stop

        $Message = "Removed NS record $($Item.NameServer)"
        Write-Log -Level Info -Message "$NodeReference - $Message"
    } catch {
        $Result  = 'Failed'
        $Message = "$_"
        Write-Log -Level Error -Message "$NodeReference - failed to remove NS record $($Item.NameServer): $Message"
    }

    $Results += [PSCustomObject]@{
        ZoneName            = $Item.ZoneName
        ZoneType            = $Item.ZoneType
        IsReverseLookupZone = $Item.IsReverseLookupZone
        RecordScope         = $Item.RecordScope
        HostName            = $Item.HostName
        NameServer          = $Item.NameServer
        ResolutionStatus    = $ResolutionStatus
        Action              = if ($WhatIf) { 'WouldRemove' } else { 'Remove' }
        Result              = $Result
        Message             = $Message
        Timestamp           = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
}

# Carry the skipped zones and guarded records into the CSV so the run is fully
# auditable.
foreach ($Item in ($WorkItems | Where-Object { $_.SkipReason })) {
    $Results += [PSCustomObject]@{
        ZoneName            = $Item.ZoneName
        ZoneType            = $Item.ZoneType
        IsReverseLookupZone = $Item.IsReverseLookupZone
        RecordScope         = $Item.RecordScope
        HostName            = $Item.HostName
        NameServer          = $Item.NameServer
        ResolutionStatus    = $ResolutionStatus
        Action              = 'Skipped'
        Result              = 'Skipped'
        Message             = $Item.SkipReason
        Timestamp           = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
}

# ----------------------------------------------------------------------------
# Step 9: Export results and finish
# ----------------------------------------------------------------------------
$Results | Export-Csv -Path $CsvOutput -NoTypeInformation -Encoding utf8
Write-Log -Level Info -Message "Results exported to $CsvOutput"

$FailedCount = @($Results | Where-Object { $_.Result -eq 'Failed' }).Count
if ($FailedCount -gt 0) {
    Write-Log -Level Warning -Message "$FailedCount NS record removal(s) failed. Review the log and CSV for details."
}

if ($WhatIf) {
    Write-Log -Level Info -Message 'Dry-run (-WhatIf) complete. No changes were made.'
} else {
    Write-Log -Level Info -Message "Removed $(@($Results | Where-Object { $_.Action -eq 'Remove' -and $_.Result -eq 'Success' }).Count) stale NS record(s). Allow time for AD replication, then re-run with -WhatIf to confirm."
}

Write-Log -Level Info -Message 'Script finished.'
