#Requires -Version 5.1
#Requires -Modules DnsServer

<#
.SYNOPSIS
    Adds or removes a domain controller as a name server (NS record) across
    DNS forward lookup zones.

.DESCRIPTION
    When a new domain controller is promoted, it should be added as a name
    server on every forward lookup zone. When an old domain controller is
    demoted, its name server delegation should be removed from those same
    zones. This script performs either action across all forward lookup
    zones on a DNS server (or a specified subset), after checking whether the
    name server is already present/absent so it only changes zones that
    actually need it.

    On -AddNameServer runs, every candidate zone is also checked (read-only)
    for whether the new DC's A (host) record has appeared and matches the
    supplied -NameServerIPAddress. This runs even for zones where the NS
    record was already present, so you can confirm a DC's DNS registration
    has caught up after promotion without re-running the whole script.

    The script must be run on a domain controller. It uses the DnsServer
    PowerShell module, which is only available on Windows with the DNS
    Server tools (RSAT-DNS-Server) installed.

    All actions and errors are logged to a timestamped .log file, and results
    are exported to a timestamped .csv file, both saved next to the script.

.PARAMETER AddNameServer
    Switch that selects the Add parameter set: adds NameServerHostName as a
    name server (NS record) on each targeted forward lookup zone that does
    not already have it.

.PARAMETER RemoveNameServer
    Switch that selects the Remove parameter set: removes NameServerHostName
    as a name server (NS record) from each targeted forward lookup zone that
    currently has it.

.PARAMETER NameServerHostName
    Fully qualified domain name of the domain controller to add or remove as
    a name server, e.g. dc03.contoso.com

.PARAMETER NameServerIPAddress
    Required with -AddNameServer. The IPv4 address of the new domain
    controller. Used to check every candidate zone for a matching A (host)
    record and report a per-zone IPVerificationStatus of Matched, Mismatch,
    or NotFound - the script never creates or modifies A records itself,
    since domain controllers self-register those via dynamic DNS update.

.PARAMETER ZoneName
    Optional. One or more forward lookup zone names to restrict the operation
    to. If omitted, all forward lookup zones on the DNS server are targeted
    (the built-in TrustAnchors zone is always excluded).

.PARAMETER ExcludeZone
    Optional. One or more forward lookup zone names to skip, in addition to
    the built-in TrustAnchors zone which is always excluded.

.PARAMETER DnsServer
    Optional. The DNS server to query and update. Defaults to the local
    computer name, since this script is expected to run on the domain
    controller that also hosts the DNS Server role.

.PARAMETER WhatIf
    Performs a dry-run: shows what would be added/removed without making any
    changes (passed through to Add-DnsServerResourceRecord /
    Remove-DnsServerResourceRecord).

.PARAMETER Force
    Skips the interactive confirmation prompt after the change summary is
    displayed. Use for unattended runs.

.EXAMPLE
    .\Update-DNSNameServer.ps1 -AddNameServer -NameServerHostName dc03.contoso.com -NameServerIPAddress 10.0.0.13

    Adds dc03.contoso.com as a name server on every forward lookup zone that
    does not already have it, after confirmation.

.EXAMPLE
    .\Update-DNSNameServer.ps1 -RemoveNameServer -NameServerHostName dc01.contoso.com -ZoneName contoso.com -Force

    Removes dc01.contoso.com as a name server from the contoso.com zone only,
    without prompting for confirmation.

.NOTES
    Author  : Michael Wang
    Version : 1.2
    Date    : 2026-07-23
    Module  : DnsServer (Windows RSAT DNS Server Tools) - Windows-only, no
              cross-platform equivalent exists for managing Windows DNS Server
              zone data.
    Requires: Must be run on a domain controller with the DnsServer module
              available, and appropriate DNS administrative privileges.
              Compatible with both Windows PowerShell 5.1 and PowerShell 7+.
#>

[CmdletBinding(DefaultParameterSetName = 'Add')]
param(
    [Parameter(Mandatory = $true, ParameterSetName = 'Add')]
    [switch]$AddNameServer,

    [Parameter(Mandatory = $true, ParameterSetName = 'Remove')]
    [switch]$RemoveNameServer,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$NameServerHostName,

    [Parameter(Mandatory = $true, ParameterSetName = 'Add')]
    [ValidateNotNullOrEmpty()]
    [string]$NameServerIPAddress,

    [string[]]$ZoneName,

    [string[]]$ExcludeZone,

    [ValidateNotNullOrEmpty()]
    [string]$DnsServer = $env:COMPUTERNAME,

    [switch]$WhatIf,

    [switch]$Force
)

# ----------------------------------------------------------------------------
# Logging setup
# ----------------------------------------------------------------------------
$ScriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
$Timestamp    = Get-Date -Format 'yyyyMMdd_HHmmss'
$LogFile      = Join-Path $ScriptFolder "Update-DNSNameServer_$Timestamp.log"
$CsvOutput    = Join-Path $ScriptFolder "Update-DNSNameServer_Results_$Timestamp.csv"

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

$Action = if ($AddNameServer) { 'Add' } else { 'Remove' }
Write-Log -Level Info -Message "Script started. Action: $Action. NameServerHostName: $NameServerHostName. DnsServer: $DnsServer"

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
# Step 2: Confirm DnsServer module is available
# ----------------------------------------------------------------------------
if (-not (Get-Module -ListAvailable -Name DnsServer)) {
    Write-Log -Level Error -Message "The DnsServer PowerShell module is not available on this machine. Install the DNS Server RSAT tools (e.g. 'Install-WindowsFeature RSAT-DNS-Server') and try again."
    return
}

# ----------------------------------------------------------------------------
# Step 3: Normalize the name server hostname
# ----------------------------------------------------------------------------
$NormalizedHostName = $NameServerHostName.TrimEnd('.')
$RecordDataHostName = "$NormalizedHostName."
$HostShortName      = $NormalizedHostName.Split('.')[0]

# ----------------------------------------------------------------------------
# Step 4: Enumerate forward lookup zones on the target DNS server
# ----------------------------------------------------------------------------
try {
    $AllZones = Get-DnsServerZone -ComputerName $DnsServer -ErrorAction Stop
} catch {
    Write-Log -Level Error -Message "Failed to retrieve DNS zones from '$DnsServer': $_"
    return
}

$AlwaysExcluded = @('TrustAnchors')
$ForwardZones = $AllZones | Where-Object {
    -not $_.IsReverseLookupZone -and
    $_.ZoneName -notin $AlwaysExcluded -and
    $_.ZoneName -notin $ExcludeZone
}

if ($ZoneName) {
    $ForwardZones = $ForwardZones | Where-Object { $_.ZoneName -in $ZoneName }
}

if (-not $ForwardZones -or @($ForwardZones).Count -eq 0) {
    Write-Log -Level Warning -Message 'No forward lookup zones matched the specified criteria. Nothing to do.'
    return
}

Write-Log -Level Info -Message "Found $(@($ForwardZones).Count) candidate forward lookup zone(s): $((($ForwardZones | ForEach-Object { $_.ZoneName }) -join ', '))"

# ----------------------------------------------------------------------------
# Step 5: Check existing state per zone
# ----------------------------------------------------------------------------
$WorkItems = @()

foreach ($Zone in $ForwardZones) {
    $ZoneNameValue = $Zone.ZoneName
    $ExistingNsHosts = @()

    try {
        $NsRecords = Get-DnsServerResourceRecord -ZoneName $ZoneNameValue -RRType Ns -Node -ComputerName $DnsServer -ErrorAction Stop
        $ExistingNsHosts = $NsRecords | ForEach-Object { $_.RecordData.NameServer.TrimEnd('.') }
    } catch {
        Write-Log -Level Warning -Message "Could not read NS records for zone '$ZoneNameValue': $_"
    }

    $AlreadyPresent = $ExistingNsHosts -contains $NormalizedHostName

    $NeedsChange = if ($AddNameServer) { -not $AlreadyPresent } else { $AlreadyPresent }

    $ARecordNote = $null
    if ($AddNameServer -and $NameServerIPAddress) {
        try {
            $ARecord = Get-DnsServerResourceRecord -ZoneName $ZoneNameValue -Name $HostShortName -RRType A -ComputerName $DnsServer -ErrorAction Stop
            $ExistingIP = $ARecord | Select-Object -First 1 -ExpandProperty RecordData | Select-Object -ExpandProperty IPv4Address -ErrorAction SilentlyContinue
            if ($ExistingIP -and $ExistingIP.ToString() -eq $NameServerIPAddress) {
                $ARecordNote = "A record already present and matches $NameServerIPAddress"
            } elseif ($ExistingIP) {
                $ARecordNote = "A record present but IP ($ExistingIP) differs from provided $NameServerIPAddress"
            } else {
                $ARecordNote = 'A record present but no IPv4 address found'
            }
        } catch {
            $ARecordNote = "No A record found for '$HostShortName' in this zone (not created by this script)"
        }
        Write-Log -Level Info -Message "Zone '$ZoneNameValue': $ARecordNote"
    }

    $WorkItems += [PSCustomObject]@{
        ZoneName       = $ZoneNameValue
        Action         = $Action
        AlreadyPresent = $AlreadyPresent
        NeedsChange    = $NeedsChange
        ARecordNote    = $ARecordNote
    }
}

$ToChange = $WorkItems | Where-Object { $_.NeedsChange }
$Skipped  = $WorkItems | Where-Object { -not $_.NeedsChange }

foreach ($Item in $Skipped) {
    $Reason = if ($AddNameServer) { 'already a name server on this zone' } else { 'not currently a name server on this zone' }
    Write-Log -Level Info -Message "Skipping zone '$($Item.ZoneName)': $NormalizedHostName is $Reason."
}

# ----------------------------------------------------------------------------
# Step 6: Summary and confirmation
# ----------------------------------------------------------------------------
if (@($ToChange).Count -eq 0) {
    Write-Host "`nNo zones require a change. Nothing to do." -ForegroundColor Green
    Write-Log -Level Info -Message 'No zones required a change. Exiting.'
    return
}

Write-Host "`n$Action name server '$NormalizedHostName' on the following zone(s):`n" -ForegroundColor Cyan
$ToChange | ForEach-Object { Write-Host "- $($_.ZoneName)" }
Write-Host "`nLog file: $LogFile`n"

if (-not $Force) {
    $Confirm = Read-Host "Proceed with $Action on the $(@($ToChange).Count) listed zone(s)? (Y/N)"
    if ($Confirm.ToUpper() -ne 'Y') {
        Write-Log -Level Info -Message 'User aborted before making any changes.'
        return
    }
}

# ----------------------------------------------------------------------------
# Step 7: Execute
# ----------------------------------------------------------------------------
$Results = @()

foreach ($Item in $ToChange) {
    $ZoneNameValue = $Item.ZoneName
    $Result = 'Success'
    $Message = ''

    try {
        if ($AddNameServer) {
            Add-DnsServerResourceRecord -ZoneName $ZoneNameValue -Name '@' -Ns -NameServer $RecordDataHostName -ComputerName $DnsServer -WhatIf:$WhatIf -ErrorAction Stop
            $Message = "Added NS record for $NormalizedHostName"
        } else {
            Remove-DnsServerResourceRecord -ZoneName $ZoneNameValue -RRType Ns -Name '@' -RecordData $RecordDataHostName -ComputerName $DnsServer -Force -WhatIf:$WhatIf -ErrorAction Stop
            $Message = "Removed NS record for $NormalizedHostName"
        }
        Write-Log -Level Info -Message "Zone '$ZoneNameValue': $Message"
    } catch {
        $Result = 'Failed'
        $Message = "$_"
        Write-Log -Level Error -Message "Zone '$ZoneNameValue': failed to $Action name server - $Message"
    }

    $Results += [PSCustomObject]@{
        ZoneName       = $ZoneNameValue
        Action         = $Action
        PreviousState  = if ($Item.AlreadyPresent) { 'Present' } else { 'Absent' }
        Result         = $Result
        Message        = $Message
        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
}

# ----------------------------------------------------------------------------
# Step 8: Export results and finish
# ----------------------------------------------------------------------------
$Results | Export-Csv -Path $CsvOutput -NoTypeInformation -Encoding utf8
Write-Log -Level Info -Message "Results exported to $CsvOutput"

$FailedCount = @($Results | Where-Object { $_.Result -eq 'Failed' }).Count
if ($FailedCount -gt 0) {
    Write-Log -Level Warning -Message "$FailedCount zone(s) failed to update. Review the log and CSV for details."
}

Write-Log -Level Info -Message 'Script finished.'
