#Requires -Version 5.1
#Requires -Modules DnsServer

<#
.SYNOPSIS
    Adds a host as a name server (NS record) across DNS zones on a domain
    controller - both zone apex NS records and delegation NS records - but only
    after verifying the host resolves and actually hosts the zone.

.DESCRIPTION
    When a domain controller is promoted, it should be registered as a name
    server on the zones it serves. Promotion normally handles the apex NS record
    for the AD-integrated domain zone, but leaves other zones - and any
    delegations in parent zones - untouched. This script fills those gaps.

    It is the counterpart to Remove-StaleNS.ps1, which cleans up NS records left
    behind by a demoted DC. Both scripts take the same parameters and share the
    same scope model, guards, and logging.

    SCOPE - TWO PLACES NS RECORDS LIVE
    NS records referencing a host exist in two distinct places, and promotion
    commonly populates one but not the other:

      ZoneRoot   - NS records at the zone apex ('@'), inside the zone itself.
                   These are the servers authoritative for THAT zone, and are
                   what DNS Manager's Name Servers tab shows.
      Delegation - NS records in the PARENT zone, stored at the child's node
                   (e.g. node 'west' inside zone contoso.com). These refer
                   queries for the child subtree elsewhere. In DNS Manager they
                   appear as greyed-out folders under the parent zone.

    Both are processed by default. Use -Scope to restrict to one. Existing
    delegations are added to; no new delegation is ever created.

    VERIFICATION GATE
    Adding an NS record for a host that cannot be reached creates exactly the
    broken delegation that Remove-StaleNS.ps1 exists to clean up: resolvers
    referred to that name server wait for a timeout before trying the next one.
    The script therefore refuses to add anything until it proves the target is
    usable. Before touching any zone it:

      1. Flushes the local DNS client cache, so a stale negative answer cannot
         cause a healthy host to be rejected.
      2. Resolves the local computer's own FQDN as a control, to distinguish
         "the target is genuinely missing" from "name resolution is broken".
      3. Resolves -TargetHostName (A and AAAA) against every server in
         -ResolutionDnsServer. The resulting status must be 'OK' - at least one
         server must return an address. A status of 'ResolveFailed' or
         'NoHostRecord' aborts the run with no changes.
      4. Queries the target itself for the list of zones it hosts. An NS record
         is only added for a zone the target is actually authoritative for. For
         a delegation at node 'west' in zone 'contoso.com', the zone checked is
         the child - 'west.contoso.com' - not the parent.

    If step 4 cannot run (the target is unreachable over RPC/WMI, or the DNS
    Server tools are unavailable) the script does not silently proceed: it logs
    the failure, prints a prominent warning above the confirmation prompt, and
    leaves the decision to the operator.

    Zones and nodes that already list the target are skipped, so the script is
    idempotent and safe to re-run.

    Glue and host (A/AAAA) records are never created. If the target's own host
    record is missing, DNS Manager's Name Servers tab will show its IP as
    "Unknown" - that is a separate fix, handled by Update-DNSNameServer.ps1.

    All actions and errors are logged to a timestamped .log file, and results
    are exported to a timestamped .csv file. Both are written to a 'logs'
    subfolder alongside the script, which is created on first run.

.PARAMETER TargetHostName
    The host to add as a name server, e.g. dc03.contoso.com

    An NS record must contain a fully qualified name. If a single label is
    supplied, the local computer's DNS domain is appended and the result is
    logged; the resolution gate then validates it, so a wrong guess aborts the
    run rather than writing a bad record.

.PARAMETER DnsServer
    Optional. The DNS server whose zones are read and modified. Defaults to the
    local computer name, since this script is expected to run on the domain
    controller that also hosts the DNS Server role.

.PARAMETER Scope
    Optional. Which NS records to add. Defaults to All.

      All        - Zone apex NS records and delegation NS records (default).
      ZoneRoot   - Only NS records at the zone apex ('@'), i.e. what DNS
                   Manager's Name Servers tab shows.
      Delegation - Only NS records at existing delegation nodes inside a parent
                   zone.

.PARAMETER ResolutionDnsServer
    Optional. One or more DNS servers used to verify -TargetHostName resolves.
    Defaults to -DnsServer. Only one server needs to resolve it for the gate to
    pass.

.PARAMETER ExcludeZone
    Optional. One or more zone names to skip, in addition to auto-created zones
    and TrustAnchors which are always excluded.

.PARAMETER WhatIf
    Performs a dry-run: shows which NS records would be added to which zones and
    nodes without making any changes (passed through to
    Add-DnsServerResourceRecord).

.PARAMETER Force
    Skips the interactive confirmation prompt after the summary is displayed.
    Use for unattended runs. This does NOT bypass the verification gate - a host
    that does not resolve is never added, with or without -Force.

.EXAMPLE
    .\Add-NS.ps1 -TargetHostName dc03.contoso.com -WhatIf

    Shows every zone apex and delegation that should list dc03.contoso.com but
    does not, without changing anything. Run this first.

.EXAMPLE
    .\Add-NS.ps1 -TargetHostName dc03.contoso.com

    Verifies dc03.contoso.com resolves and hosts the zones concerned, lists what
    will be added, prompts for confirmation, then adds the NS records.

.EXAMPLE
    .\Add-NS.ps1 -TargetHostName dc03.contoso.com -Scope Delegation -WhatIf

    Shows only the delegation NS records (the greyed-out folders in DNS Manager)
    that dc03.contoso.com is missing from, leaving zone apex records alone.

.EXAMPLE
    .\Add-NS.ps1 -TargetHostName dc03.contoso.com -ExcludeZone legacy.contoso.com -Force

    Adds the name server everywhere it is missing except legacy.contoso.com,
    without prompting.

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
    See also: Remove-StaleNS.ps1 - the removal counterpart, same parameters.
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
$LogFile      = Join-Path $LogFolder "Add-NS_$Timestamp.log"
$CsvOutput    = Join-Path $LogFolder "Add-NS_Results_$Timestamp.csv"

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
#
# An NS record's data must be a fully qualified name, so unlike the removal
# script a single label cannot be matched loosely - it has to be completed. The
# resolution gate below then validates the result.
# ----------------------------------------------------------------------------
$NormalizedTarget = $TargetHostName.TrimEnd('.')

if (-not $NormalizedTarget.Contains('.')) {
    if ([string]::IsNullOrWhiteSpace($ComputerSystem.Domain)) {
        Write-Log -Level Error -Message "'$TargetHostName' is a single label and the local DNS domain could not be determined. Supply the fully qualified name. Aborting."
        return
    }
    $NormalizedTarget = "$NormalizedTarget.$($ComputerSystem.Domain)"
    Write-Log -Level Warning -Message "'$TargetHostName' is a single label. Using '$NormalizedTarget' (local DNS domain appended). Verify this is correct before confirming."
}

# NS record data is stored fully qualified, with a trailing dot.
$RecordDataHostName = "$NormalizedTarget."

# ----------------------------------------------------------------------------
# Step 4: VERIFICATION GATE - prove the target resolves
#
# Sub-step 4a: flush the local resolver cache so a stale negative answer cannot
# cause a healthy host to be rejected.
# ----------------------------------------------------------------------------
try {
    Clear-DnsClientCache -ErrorAction Stop
    Write-Log -Level Info -Message 'Flushed local DNS client cache before resolution test.'
} catch {
    Write-Log -Level Warning -Message "Could not flush the local DNS client cache: $_. Continuing - the resolution test may use cached data."
}

# Sub-step 4b: control test, so a broken resolver is reported as such rather
# than being misread as "the target host does not exist".
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
    Write-Log -Level Error -Message "Control lookup failed: none of the resolution servers could resolve this computer's own FQDN '$LocalFqdn'. Name resolution is unhealthy, so the result for '$NormalizedTarget' would not be trustworthy. Aborting without changes."
    return
}
Write-Log -Level Info -Message "Control lookup succeeded - '$LocalFqdn' resolves, so the resolution test is trustworthy."

# Sub-step 4c: the target must resolve to an address on at least one server.
$ResolvedAddresses = @()
$ResolutionStatus  = 'ResolveFailed'

foreach ($Server in $ResolutionDnsServer) {
    try {
        $Answer    = Resolve-DnsName -Name $NormalizedTarget -Type A_AAAA -Server $Server -DnsOnly -ErrorAction Stop
        $Addresses = @($Answer | Where-Object { $_.QueryType -in 'A', 'AAAA' } | ForEach-Object { $_.IPAddress })

        if ($Addresses.Count -gt 0) {
            $ResolvedAddresses += $Addresses
            $ResolutionStatus = 'OK'
            Write-Log -Level Info -Message "'$NormalizedTarget' resolved on '$Server' to: $($Addresses -join ', ')"
        } elseif ($ResolutionStatus -ne 'OK') {
            $ResolutionStatus = 'NoHostRecord'
            Write-Log -Level Warning -Message "'$NormalizedTarget' exists in DNS on '$Server' but returned no A/AAAA record."
        }
    } catch {
        Write-Log -Level Warning -Message "'$NormalizedTarget' did not resolve on '$Server': $($_.Exception.Message)"
    }
}

if ($ResolutionStatus -ne 'OK') {
    Write-Log -Level Error -Message "Verification gate failed. Required status 'OK' but got '$ResolutionStatus' for '$NormalizedTarget'. Adding an NS record for a host that does not resolve would create a broken delegation, so no changes will be made."
    if ($ResolutionStatus -eq 'NoHostRecord') {
        Write-Log -Level Error -Message "Status 'NoHostRecord' means the name exists but has no address. Create its A/AAAA record first, then re-run."
    } else {
        Write-Log -Level Error -Message "Status 'ResolveFailed' means the name does not exist in DNS at all. Check the spelling, or register the host's A/AAAA record first (ipconfig /registerdns on the target)."
    }
    return
}
$UniqueAddresses = @($ResolvedAddresses | Select-Object -Unique)
Write-Log -Level Info -Message "Verification gate passed. '$NormalizedTarget' resolves to: $($UniqueAddresses -join ', ')."

# ----------------------------------------------------------------------------
# Step 5: Determine which zones the target actually hosts
#
# A name server that is not authoritative for the zone it is listed on is a lame
# delegation. One query to the target returns every zone it hosts, which is far
# cheaper than probing per zone.
# ----------------------------------------------------------------------------
$TargetHostedZones  = New-Object 'System.Collections.Generic.HashSet[string]' ([StringComparer]::OrdinalIgnoreCase)
$ZoneHostCheckRan   = $false
$ZoneHostCheckError = $null

try {
    $TargetZones = Get-DnsServerZone -ComputerName $NormalizedTarget -ErrorAction Stop
    foreach ($TargetZone in $TargetZones) {
        [void]$TargetHostedZones.Add($TargetZone.ZoneName)
    }
    $ZoneHostCheckRan = $true
    Write-Log -Level Info -Message "'$NormalizedTarget' hosts $($TargetHostedZones.Count) zone(s). NS records will only be added for zones it is authoritative for."
} catch {
    $ZoneHostCheckError = "$($_.Exception.Message)"
    Write-Log -Level Warning -Message "Could not query the zone list from '$NormalizedTarget': $ZoneHostCheckError"
    Write-Log -Level Warning -Message 'The authority check could not run. Every candidate zone will be listed, but adding a name server for a zone the target does not host creates a lame delegation - review the summary carefully.'
}

# ----------------------------------------------------------------------------
# Step 6: Enumerate all forward and reverse lookup zones
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
Write-Log -Level Info -Message "Scanning $(@($Zones).Count) zone(s) - forward and reverse - for places '$NormalizedTarget' should be listed ($ScopeDescription)."

# ----------------------------------------------------------------------------
# Step 7: Work out where the name server is missing
# ----------------------------------------------------------------------------
$WorkItems = @()
$ZoneIndex = 0
$ZoneCount = @($Zones).Count

foreach ($Zone in $Zones) {
    $ZoneIndex++
    $ZoneNameValue = $Zone.ZoneName
    Write-Progress -Activity 'Scanning zones for missing NS records' -Status $ZoneNameValue -PercentComplete (($ZoneIndex / $ZoneCount) * 100)

    # Secondary/Stub zone data is owned by the master and cannot be edited here;
    # Forwarder zones hold no NS records. Record them so the skip is visible in
    # the output rather than silently dropped.
    if ($Zone.ZoneType -ne 'Primary') {
        Write-Log -Level Info -Message "Skipping zone '$ZoneNameValue': ZoneType '$($Zone.ZoneType)' is not writable on this server."
        $WorkItems += [PSCustomObject]@{
            ZoneName            = $ZoneNameValue
            ZoneType            = $Zone.ZoneType
            IsReverseLookupZone = $Zone.IsReverseLookupZone
            RecordScope         = $null
            HostName            = $null
            ServedZone          = $null
            NeedsAdd            = $false
            SkipReason          = "ZoneType '$($Zone.ZoneType)' is not writable on this server"
        }
        continue
    }

    try {
        # No -Node: returns NS records from every node in the zone, so the apex
        # and all delegation nodes are covered in a single query per zone.
        $NsRecords = Get-DnsServerResourceRecord -ZoneName $ZoneNameValue -RRType Ns -ComputerName $DnsServer -ErrorAction Stop
    } catch {
        Write-Log -Level Warning -Message "Could not read NS records for zone '$ZoneNameValue': $_"
        $WorkItems += [PSCustomObject]@{
            ZoneName            = $ZoneNameValue
            ZoneType            = $Zone.ZoneType
            IsReverseLookupZone = $Zone.IsReverseLookupZone
            RecordScope         = $null
            HostName            = $null
            ServedZone          = $null
            NeedsAdd            = $false
            SkipReason          = "Failed to read NS records: $_"
        }
        continue
    }

    # A zone with no NS records at all still needs an apex entry, so the apex is
    # evaluated explicitly rather than relying on a node group existing.
    $NodeNames = @($NsRecords | ForEach-Object { $_.HostName } | Select-Object -Unique)
    if ($NodeNames -notcontains '@') {
        $NodeNames += '@'
    }

    foreach ($NodeName in $NodeNames) {
        # '@' is the zone apex (the Name Servers tab). Any other node name is a
        # delegation handing the child subtree off to another set of servers.
        if ($NodeName -eq '@') {
            $RecordScope   = 'ZoneRoot'
            $ServedZone    = $ZoneNameValue
            $NodeReference = "zone '$ZoneNameValue' apex"
        } else {
            $RecordScope = 'Delegation'
            # The name server must be authoritative for the CHILD zone, not the
            # parent that stores the delegation.
            $ServedZone    = "$NodeName.$ZoneNameValue"
            $NodeReference = "delegation '$NodeName' in zone '$ZoneNameValue' (child zone '$ServedZone')"
        }

        if ($Scope -ne 'All' -and $Scope -ne $RecordScope) {
            continue
        }

        # Idempotency: skip if the target is already listed on this node.
        $NodeRecords = @($NsRecords | Where-Object { $_.HostName -eq $NodeName })
        $AlreadyListed = $false
        foreach ($Record in $NodeRecords) {
            if ($Record.RecordData.NameServer.TrimEnd('.') -eq $NormalizedTarget) {
                $AlreadyListed = $true
                break
            }
        }

        if ($AlreadyListed) {
            Write-Log -Level Info -Message "$NodeReference - already lists '$NormalizedTarget'. No change needed."
            $WorkItems += [PSCustomObject]@{
                ZoneName            = $ZoneNameValue
                ZoneType            = $Zone.ZoneType
                IsReverseLookupZone = $Zone.IsReverseLookupZone
                RecordScope         = $RecordScope
                HostName            = $NodeName
                ServedZone          = $ServedZone
                NeedsAdd            = $false
                SkipReason          = 'Already listed as a name server'
            }
            continue
        }

        # Authority check: adding a name server that is not authoritative for
        # the served zone produces a lame delegation.
        if ($ZoneHostCheckRan -and -not $TargetHostedZones.Contains($ServedZone)) {
            Write-Log -Level Warning -Message "$NodeReference - skipped: '$NormalizedTarget' does not host zone '$ServedZone', so listing it would create a lame delegation."
            $WorkItems += [PSCustomObject]@{
                ZoneName            = $ZoneNameValue
                ZoneType            = $Zone.ZoneType
                IsReverseLookupZone = $Zone.IsReverseLookupZone
                RecordScope         = $RecordScope
                HostName            = $NodeName
                ServedZone          = $ServedZone
                NeedsAdd            = $false
                SkipReason          = "Target does not host zone '$ServedZone'"
            }
            continue
        }

        Write-Log -Level Warning -Message "$NodeReference - missing '$NormalizedTarget'. It will be added."
        $WorkItems += [PSCustomObject]@{
            ZoneName            = $ZoneNameValue
            ZoneType            = $Zone.ZoneType
            IsReverseLookupZone = $Zone.IsReverseLookupZone
            RecordScope         = $RecordScope
            HostName            = $NodeName
            ServedZone          = $ServedZone
            NeedsAdd            = $true
            SkipReason          = $null
        }
    }
}
Write-Progress -Activity 'Scanning zones for missing NS records' -Completed

$ToAdd           = @($WorkItems | Where-Object { $_.NeedsAdd })
$AlreadyPresent  = @($WorkItems | Where-Object { $_.SkipReason -eq 'Already listed as a name server' })
$NotAuthoritative = @($WorkItems | Where-Object { $_.SkipReason -like "Target does not host zone*" })

# ----------------------------------------------------------------------------
# Step 8: Summary and confirmation
# ----------------------------------------------------------------------------
if ($ToAdd.Count -eq 0) {
    Write-Host "`nNothing to add - '$NormalizedTarget' is already listed everywhere it should be ($($AlreadyPresent.Count) existing entr(ies), $($NotAuthoritative.Count) zone(s) it does not host)." -ForegroundColor Green
    Write-Log -Level Info -Message "No NS records need to be added for '$NormalizedTarget'. Exiting."
    return
}

Write-Host "`nAdd name server '$NormalizedTarget' to the following:`n" -ForegroundColor Cyan

$RootItems = @($ToAdd | Where-Object { $_.RecordScope -eq 'ZoneRoot' })
if ($RootItems.Count -gt 0) {
    Write-Host '  Zone apex (Name Servers tab):' -ForegroundColor Cyan
    $RootItems | ForEach-Object { Write-Host "    - $($_.ZoneName)" }
}

$DelegationItems = @($ToAdd | Where-Object { $_.RecordScope -eq 'Delegation' })
if ($DelegationItems.Count -gt 0) {
    Write-Host '  Delegations (records stored in the parent zone):' -ForegroundColor Cyan
    $DelegationItems | ForEach-Object { Write-Host "    - $($_.ZoneName) -> node '$($_.HostName)' (serves '$($_.ServedZone)')" }
}

if ($AlreadyPresent.Count -gt 0) {
    Write-Host "`n  $($AlreadyPresent.Count) location(s) already list this name server and will be left alone." -ForegroundColor Green
}

if ($NotAuthoritative.Count -gt 0) {
    Write-Host "`n  $($NotAuthoritative.Count) location(s) skipped because '$NormalizedTarget' does not host the zone concerned." -ForegroundColor Yellow
}

# If the authority check could not run, say so loudly - the operator is the only
# remaining safeguard against creating a lame delegation.
if (-not $ZoneHostCheckRan) {
    Write-Host "`nWARNING: could not verify which zones '$NormalizedTarget' hosts ($ZoneHostCheckError)." -ForegroundColor Yellow
    Write-Host "         The list above is UNVERIFIED. Adding a name server for a zone it does not host" -ForegroundColor Yellow
    Write-Host "         creates a lame delegation. Confirm the target hosts every zone listed." -ForegroundColor Yellow
}

Write-Host "`nLog file: $LogFile`n"

if (-not $Force -and -not $WhatIf) {
    $Confirm = Read-Host "Proceed with $($ToAdd.Count) addition(s)? (Y/N)"
    if ($Confirm.ToUpper() -ne 'Y') {
        Write-Log -Level Info -Message 'User aborted before making any changes.'
        return
    }
}

# ----------------------------------------------------------------------------
# Step 9: Add the NS records
# ----------------------------------------------------------------------------
$Results = @()

foreach ($Item in $ToAdd) {
    $Result  = 'Success'
    $Message = ''

    if ($Item.RecordScope -eq 'Delegation') {
        $NodeReference = "delegation '$($Item.HostName)' in zone '$($Item.ZoneName)'"
    } else {
        $NodeReference = "zone '$($Item.ZoneName)' apex"
    }

    try {
        # Add-DnsServerZoneDelegation is the purpose-built cmdlet for delegation
        # nodes, but it creates a delegation and requires glue IP addresses.
        # Adding the single NS resource record keeps behaviour identical for both
        # scopes, adds to existing delegations rather than replacing them, and
        # creates no glue or host records as a side effect.
        Add-DnsServerResourceRecord -ZoneName $Item.ZoneName `
                                    -Name $Item.HostName `
                                    -NS `
                                    -NameServer $RecordDataHostName `
                                    -ComputerName $DnsServer `
                                    -WhatIf:$WhatIf `
                                    -ErrorAction Stop

        $Message = "Added NS record $RecordDataHostName"
        Write-Log -Level Info -Message "$NodeReference - $Message"
    } catch {
        $Result  = 'Failed'
        $Message = "$_"
        Write-Log -Level Error -Message "$NodeReference - failed to add NS record ${RecordDataHostName}: $Message"
    }

    $Results += [PSCustomObject]@{
        ZoneName            = $Item.ZoneName
        ZoneType            = $Item.ZoneType
        IsReverseLookupZone = $Item.IsReverseLookupZone
        RecordScope         = $Item.RecordScope
        HostName            = $Item.HostName
        ServedZone          = $Item.ServedZone
        NameServer          = $RecordDataHostName
        ResolutionStatus    = $ResolutionStatus
        ResolvedAddress     = ($UniqueAddresses -join ', ')
        Action              = if ($WhatIf) { 'WouldAdd' } else { 'Add' }
        Result              = $Result
        Message             = $Message
        Timestamp           = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
}

# Carry the skipped entries into the CSV so the run is fully auditable.
foreach ($Item in ($WorkItems | Where-Object { $_.SkipReason })) {
    $Results += [PSCustomObject]@{
        ZoneName            = $Item.ZoneName
        ZoneType            = $Item.ZoneType
        IsReverseLookupZone = $Item.IsReverseLookupZone
        RecordScope         = $Item.RecordScope
        HostName            = $Item.HostName
        ServedZone          = $Item.ServedZone
        NameServer          = $RecordDataHostName
        ResolutionStatus    = $ResolutionStatus
        ResolvedAddress     = ($UniqueAddresses -join ', ')
        Action              = 'Skipped'
        Result              = 'Skipped'
        Message             = $Item.SkipReason
        Timestamp           = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
}

# ----------------------------------------------------------------------------
# Step 10: Export results and finish
# ----------------------------------------------------------------------------
$Results | Export-Csv -Path $CsvOutput -NoTypeInformation -Encoding utf8
Write-Log -Level Info -Message "Results exported to $CsvOutput"

$FailedCount = @($Results | Where-Object { $_.Result -eq 'Failed' }).Count
if ($FailedCount -gt 0) {
    Write-Log -Level Warning -Message "$FailedCount NS record addition(s) failed. Review the log and CSV for details."
}

if ($WhatIf) {
    Write-Log -Level Info -Message 'Dry-run (-WhatIf) complete. No changes were made.'
} else {
    Write-Log -Level Info -Message "Added $(@($Results | Where-Object { $_.Action -eq 'Add' -and $_.Result -eq 'Success' }).Count) NS record(s). Allow time for AD replication, then re-run with -WhatIf to confirm."
    Write-Log -Level Info -Message "If DNS Manager shows the new name server's IP as 'Unknown', its A record is missing - see Update-DNSNameServer.ps1."
}

Write-Log -Level Info -Message 'Script finished.'
