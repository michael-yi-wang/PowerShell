#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication
<#
.SYNOPSIS
    Converts a dynamic-membership Entra ID group to an assigned (static) group while preserving
    its members and, for Teams-connected groups, its private/shared channel memberships.

.DESCRIPTION
    The script performs the following phases, pausing for confirmation at critical points:

      1. Discovery   - Locates the group by display name, verifies it has dynamic membership, and
                       identifies whether it is a Microsoft 365 group, Teams-connected, and/or
                       (best effort) a Viva Engage community.
      2. Snapshot    - Captures the current group members and, for Teams, the direct members of every
                       private and shared channel. Snapshots are exported to CSV BEFORE any change.
      3. Conversion  - Removes "DynamicMembership" from groupTypes and pauses the membership rule,
                       keeping every other groupTypes value (e.g. "Unified").
      4. Restore     - Re-reads group membership and adds back any snapshot member that is missing
                       (batched, 20 per request).
      5. Channels    - For Teams groups, adds back any private/shared channel member (with the original
                       owner role) that is missing. Failed adds are retried in passes, because Teams can
                       lag behind Entra ID when membership changes.
      6. Verification- Compares final state against the snapshot and exports a results CSV.

    Standard channels are not processed: their membership is inherited from the team itself.

    All Graph calls are made with Invoke-MgGraphRequest, so only Microsoft.Graph.Authentication is needed.

.PARAMETER GroupName
    Display name of the dynamic group to convert. Must match exactly one group.

.PARAMETER TenantId
    Optional tenant ID (GUID or domain) used when a new Graph connection is created.

.PARAMETER SkipChannels
    Do not snapshot or restore private/shared channel membership for Teams-connected groups.

.PARAMETER ChannelRetryCount
    Number of extra passes to retry failed channel member adds. Default: 5.

.PARAMETER ChannelRetryDelaySeconds
    Seconds to wait between channel retry passes. Default: 60.

.PARAMETER Force
    Skip interactive confirmation prompts. Use with care.

.PARAMETER WhatIf
    Run discovery and snapshot (including CSV export) only; no changes are made.

.EXAMPLE
    .\Convert-DynGroupToAsgGroup.ps1 -GroupName "Sales Team" -WhatIf

    Discovers the group, exports the member / channel member snapshot, and stops without making changes.

.EXAMPLE
    .\Convert-DynGroupToAsgGroup.ps1 -GroupName "Sales Team" -TenantId "contoso.onmicrosoft.com"

    Converts "Sales Team" to assigned membership with interactive confirmations.

.NOTES
    Author      : Michael
    Date        : 2026-10-14
    Requirements: PowerShell 7+, Microsoft.Graph.Authentication module
    Permissions : Group.ReadWrite.All, GroupMember.ReadWrite.All,
                  Channel.ReadBasic.All, ChannelMember.ReadWrite.All (delegated)
    Roles       : Groups Administrator (group conversion) and Teams Administrator (channel membership),
                  or equivalent.

    References:
      - Change membership type (dynamic <-> static):
        https://learn.microsoft.com/entra/identity/users/groups-change-type
      - group resource (groupTypes, resourceProvisioningOptions):
        https://learn.microsoft.com/graph/api/resources/group?view=graph-rest-1.0
      - Add members (max 20 per request):
        https://learn.microsoft.com/graph/api/group-post-members?view=graph-rest-1.0
      - List channel members (direct members of private/shared channels):
        https://learn.microsoft.com/graph/api/channel-list-members?view=graph-rest-1.0
      - Add member to channel (private/shared only; roles "owner" or empty):
        https://learn.microsoft.com/graph/api/channel-post-members?view=graph-rest-1.0
#>

[CmdletBinding(SupportsShouldProcess)]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$GroupName,

    [string]$TenantId,

    [switch]$SkipChannels,

    [ValidateRange(0, 20)]
    [int]$ChannelRetryCount = 5,

    [ValidateRange(10, 600)]
    [int]$ChannelRetryDelaySeconds = 60,

    [switch]$Force
)

$ErrorActionPreference = 'Stop'

# --- Logging ---
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$scriptName = 'Convert-DynGroupToAsgGroup'
$logFile = Join-Path $PSScriptRoot "${scriptName}_$timestamp.log"

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $logFile -Value $entry
    switch ($Level) {
        'Info'    { Write-Host $entry -ForegroundColor Green }
        'Warning' { Write-Host $entry -ForegroundColor Yellow }
        'Error'   { Write-Host $entry -ForegroundColor Red }
    }
}

# --- Helpers ---

# Follows @odata.nextLink and emits every item of a Graph collection
function Get-GraphCollection {
    param ([string]$Uri)
    while ($Uri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
        if ($response.value) { $response.value }
        $Uri = $response.'@odata.nextLink'
    }
}

function Get-GraphErrorStatus {
    param ($ErrorRecord)
    try { [int]$ErrorRecord.Exception.Response.StatusCode } catch { 0 }
}

# Returns $true when the operator confirms (or -Force is set). If $ExpectedText is set, it must be typed exactly.
function Confirm-Step {
    param (
        [string]$Message,
        [string]$ExpectedText = 'YES'
    )
    if ($Force) {
        Write-Log "Auto-confirmed (-Force): $Message" -Level Warning
        return $true
    }
    Write-Host ''
    Write-Host $Message -ForegroundColor Cyan
    $answer = Read-Host "Type '$ExpectedText' to continue (anything else aborts)"
    $confirmed = $answer -ceq $ExpectedText
    Write-Log "Confirmation '$Message' -> $(if ($confirmed) { 'accepted' } else { 'declined' })" -Level $(if ($confirmed) { 'Info' } else { 'Warning' })
    return $confirmed
}

function Get-GroupMemberSnapshot {
    param ([string]$GroupId)
    @(Get-GraphCollection -Uri "v1.0/groups/$GroupId/members?`$select=id,displayName,userPrincipalName,mail&`$top=999" |
        ForEach-Object {
            [PSCustomObject]@{
                Id                = $_.id
                ObjectType        = ($_.'@odata.type' -replace '#microsoft.graph.', '')
                DisplayName       = $_.displayName
                UserPrincipalName = $_.userPrincipalName
                Mail              = $_.mail
            }
        })
}

function Get-ChannelMemberSnapshot {
    param ([string]$TeamId, [object]$Channel)
    # /members returns the direct members of private and shared channels
    @(Get-GraphCollection -Uri "v1.0/teams/$TeamId/channels/$($Channel.id)/members?`$top=999" |
        Where-Object { $_.userId } |
        ForEach-Object {
            [PSCustomObject]@{
                ChannelId      = $Channel.id
                ChannelName    = $Channel.displayName
                MembershipType = $Channel.membershipType
                UserId         = $_.userId
                DisplayName    = $_.displayName
                Email          = $_.email
                Roles          = (@($_.roles) -join ';')
                TenantId       = $_.tenantId
            }
        })
}

# --- Connect to Microsoft Graph ---
$requiredScopes = @('Group.ReadWrite.All', 'GroupMember.ReadWrite.All', 'Channel.ReadBasic.All', 'ChannelMember.ReadWrite.All')
$connected = $false
$results = [System.Collections.Generic.List[object]]::new()
$safeName = ($GroupName -replace '[^\w\-]', '_')

try {
    $context = Get-MgContext
    if ($context) {
        Write-Log "Using existing Microsoft Graph session ($($context.Account), tenant $($context.TenantId))."
        $missingScopes = @($requiredScopes | Where-Object { $_ -notin $context.Scopes })
        if ($missingScopes.Count -gt 0) {
            Write-Log "Current session is missing scope(s): $($missingScopes -join ', '). Some steps may fail." -Level Warning
        }
    } else {
        Write-Log 'Connecting to Microsoft Graph...'
        $connectParams = @{ Scopes = $requiredScopes; NoWelcome = $true }
        if ($TenantId) { $connectParams.TenantId = $TenantId }
        Connect-MgGraph @connectParams
        $connected = $true
        $context = Get-MgContext
        Write-Log "Connected as $($context.Account) (tenant $($context.TenantId))."
    }
    $homeTenantId = $context.TenantId

    # =====================================================================
    # Phase 1 - Discovery
    # =====================================================================
    Write-Log "Looking up group '$GroupName'..."
    $escapedName = $GroupName -replace "'", "''"
    $filter = [uri]::EscapeDataString("displayName eq '$escapedName'")
    $select = 'id,displayName,mail,groupTypes,membershipRule,membershipRuleProcessingState,resourceProvisioningOptions,securityEnabled,mailEnabled'
    $found = @(Get-GraphCollection -Uri "v1.0/groups?`$filter=$filter&`$select=$select")

    if ($found.Count -eq 0) {
        Write-Log "No group found with display name '$GroupName'." -Level Error
        return
    }
    if ($found.Count -gt 1) {
        Write-Log "$($found.Count) groups share the display name '$GroupName'. Rename or resolve the duplicate first:" -Level Error
        $found | ForEach-Object { Write-Log "  - $($_.id) ($($_.mail))" -Level Error }
        return
    }

    $group = $found[0]
    $groupId = $group.id
    $groupTypes = @($group.groupTypes)

    if ($groupTypes -notcontains 'DynamicMembership') {
        Write-Log "Group '$($group.displayName)' does not have dynamic membership (groupTypes: [$($groupTypes -join ', ')]). Nothing to convert." -Level Error
        return
    }

    $isM365 = $groupTypes -contains 'Unified'
    $isTeam = @($group.resourceProvisioningOptions) -contains 'Team'

    # Viva Engage detection is best effort: creationOptions is returned by default on v1.0 but is not a
    # documented property, so a missing/unknown value only means "not detected", not "not Viva Engage".
    $isVivaEngage = $false
    if ($isM365) {
        try {
            $fullGroup = Invoke-MgGraphRequest -Method GET -Uri "v1.0/groups/$groupId" -OutputType PSObject
            $isVivaEngage = [bool](@($fullGroup.creationOptions) -match 'Yammer')
        } catch {
            Write-Log "Could not read creationOptions for Viva Engage detection: $($_.Exception.Message)" -Level Warning
        }
    }

    $workloads = @()
    if ($isTeam)       { $workloads += 'Microsoft Teams' }
    if ($isVivaEngage) { $workloads += 'Viva Engage (best-effort detection)' }

    Write-Log '----- Group details -----'
    Write-Log "Display name     : $($group.displayName)"
    Write-Log "Object ID        : $groupId"
    Write-Log "Mail             : $($group.mail)"
    Write-Log "Group type       : $(if ($isM365) { 'Microsoft 365 group' } elseif ($group.securityEnabled) { 'Security group' } else { 'Other' })"
    Write-Log "groupTypes       : [$($groupTypes -join ', ')]"
    Write-Log "Connected to     : $(if ($workloads) { $workloads -join ', ' } else { 'None detected' })"
    Write-Log "Membership rule  : $($group.membershipRule)"
    Write-Log "Rule processing  : $($group.membershipRuleProcessingState)"

    if (-not $isM365) {
        Write-Log 'This is NOT a Microsoft 365 group. Conversion is still possible, but Teams/Viva Engage handling does not apply.' -Level Warning
        if (-not (Confirm-Step -Message "Continue converting non-Microsoft 365 group '$($group.displayName)'?")) { return }
    }
    if ($group.membershipRuleProcessingState -ne 'On') {
        Write-Log "Rule processing is '$($group.membershipRuleProcessingState)'. Current membership may not reflect the rule; it will be preserved as-is." -Level Warning
    }

    # =====================================================================
    # Phase 2 - Snapshot (always exported before any change)
    # =====================================================================
    Write-Log 'Capturing current group membership...'
    $memberSnapshot = Get-GroupMemberSnapshot -GroupId $groupId
    Write-Log "Captured $($memberSnapshot.Count) group member(s)."

    $memberCsv = Join-Path $PSScriptRoot "${scriptName}_${safeName}_GroupMembers_$timestamp.csv"
    $memberSnapshot | Export-Csv -Path $memberCsv -NoTypeInformation -Encoding UTF8
    Write-Log "Group member snapshot exported to: $memberCsv"

    $channelSnapshot = @()
    $targetChannels = @()
    if ($isTeam -and -not $SkipChannels) {
        Write-Log 'Enumerating team channels...'
        $channels = @(Get-GraphCollection -Uri "v1.0/teams/$groupId/channels?`$select=id,displayName,membershipType")
        $targetChannels = @($channels | Where-Object { $_.membershipType -in 'private', 'shared' })
        Write-Log "Found $($channels.Count) channel(s); $($targetChannels.Count) private/shared channel(s) to snapshot."

        foreach ($channel in $targetChannels) {
            $members = Get-ChannelMemberSnapshot -TeamId $groupId -Channel $channel
            Write-Log "  [$($channel.membershipType)] '$($channel.displayName)': $($members.Count) direct member(s)."
            $channelSnapshot += $members
        }

        $channelCsv = Join-Path $PSScriptRoot "${scriptName}_${safeName}_ChannelMembers_$timestamp.csv"
        $channelSnapshot | Export-Csv -Path $channelCsv -NoTypeInformation -Encoding UTF8
        Write-Log "Channel member snapshot exported to: $channelCsv"
    } elseif ($isTeam) {
        Write-Log 'Teams-connected group, but -SkipChannels was specified. Channel membership will not be restored.' -Level Warning
    }

    if ($memberSnapshot.Count -eq 0) {
        Write-Log 'The group currently has no members. After conversion it will remain empty.' -Level Warning
    }

    # =====================================================================
    # Phase 3 - Conversion (critical step)
    # =====================================================================
    $newGroupTypes = @($groupTypes | Where-Object { $_ -ne 'DynamicMembership' })

    if (-not $PSCmdlet.ShouldProcess("$($group.displayName) ($groupId)", 'Convert dynamic membership to assigned')) {
        Write-Log 'WhatIf: snapshot complete, no changes made.'
        return
    }

    Write-Log "Record this rule if you need to roll back: $($group.membershipRule)" -Level Warning
    $prompt = "About to convert '$($group.displayName)' from DYNAMIC to ASSIGNED membership.`n" +
              "  - $($memberSnapshot.Count) member(s) and $($channelSnapshot.Count) channel membership(s) were captured.`n" +
              "  - The membership rule will stop being evaluated.`n" +
              'Type the group display name exactly to proceed.'
    if (-not (Confirm-Step -Message $prompt -ExpectedText $group.displayName)) {
        Write-Log 'Conversion aborted by operator. No changes made.' -Level Warning
        return
    }

    Write-Log "Updating groupTypes to [$($newGroupTypes -join ', ')] and pausing rule processing..."
    $body = @{ groupTypes = $newGroupTypes; membershipRuleProcessingState = 'Paused' } | ConvertTo-Json -Depth 3
    Invoke-MgGraphRequest -Method PATCH -Uri "v1.0/groups/$groupId" -Body $body -ContentType 'application/json'

    # Verify the conversion has been applied
    $converted = $false
    for ($i = 1; $i -le 6; $i++) {
        $check = Invoke-MgGraphRequest -Method GET -Uri "v1.0/groups/$groupId`?`$select=groupTypes,membershipRuleProcessingState" -OutputType PSObject
        if (@($check.groupTypes) -notcontains 'DynamicMembership') { $converted = $true; break }
        Start-Sleep -Seconds 5
    }
    if (-not $converted) {
        Write-Log 'Group still reports DynamicMembership after update. Stopping before restore; investigate in the Entra admin center.' -Level Error
        return
    }
    Write-Log "Group converted. groupTypes: [$(@($check.groupTypes) -join ', ')], rule processing: $($check.membershipRuleProcessingState)."

    # =====================================================================
    # Phase 4 - Restore group membership
    # =====================================================================
    Write-Log 'Re-reading group membership after conversion...'
    $currentIds = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(Get-GroupMemberSnapshot -GroupId $groupId | ForEach-Object Id))
    $missingMembers = @($memberSnapshot | Where-Object { -not $currentIds.Contains($_.Id) })
    Write-Log "$($currentIds.Count) member(s) present; $($missingMembers.Count) missing compared to the snapshot."

    foreach ($m in $memberSnapshot | Where-Object { $currentIds.Contains($_.Id) }) {
        $results.Add([PSCustomObject]@{ Scope = 'Group'; Channel = ''; Id = $m.Id; DisplayName = $m.DisplayName; Result = 'AlreadyPresent'; Detail = '' })
    }

    if ($missingMembers.Count -gt 0) {
        if (-not (Confirm-Step -Message "Add $($missingMembers.Count) missing member(s) back to '$($group.displayName)'?")) {
            Write-Log 'Group member restore skipped by operator. Use the snapshot CSV to restore manually.' -Level Warning
        } else {
            # Graph accepts up to 20 members per PATCH request
            for ($i = 0; $i -lt $missingMembers.Count; $i += 20) {
                $batch = @($missingMembers[$i..([Math]::Min($i + 19, $missingMembers.Count - 1))])
                $bindBody = @{ 'members@odata.bind' = @($batch | ForEach-Object { "https://graph.microsoft.com/v1.0/directoryObjects/$($_.Id)" }) } |
                    ConvertTo-Json -Depth 3
                try {
                    Invoke-MgGraphRequest -Method PATCH -Uri "v1.0/groups/$groupId" -Body $bindBody -ContentType 'application/json'
                    foreach ($m in $batch) {
                        $results.Add([PSCustomObject]@{ Scope = 'Group'; Channel = ''; Id = $m.Id; DisplayName = $m.DisplayName; Result = 'Added'; Detail = '' })
                    }
                    Write-Log "Added batch of $($batch.Count) member(s)."
                } catch {
                    # One bad reference fails the whole batch; fall back to one-by-one to isolate it
                    Write-Log "Batch add failed ($($_.Exception.Message)); retrying members individually." -Level Warning
                    foreach ($m in $batch) {
                        $refBody = @{ '@odata.id' = "https://graph.microsoft.com/v1.0/directoryObjects/$($m.Id)" } | ConvertTo-Json
                        try {
                            Invoke-MgGraphRequest -Method POST -Uri "v1.0/groups/$groupId/members/`$ref" -Body $refBody -ContentType 'application/json'
                            $results.Add([PSCustomObject]@{ Scope = 'Group'; Channel = ''; Id = $m.Id; DisplayName = $m.DisplayName; Result = 'Added'; Detail = '' })
                        } catch {
                            $msg = $_.Exception.Message
                            $result = if ($msg -match 'already exist') { 'AlreadyPresent' } else { 'Failed' }
                            $results.Add([PSCustomObject]@{ Scope = 'Group'; Channel = ''; Id = $m.Id; DisplayName = $m.DisplayName; Result = $result; Detail = $msg })
                            if ($result -eq 'Failed') { Write-Log "Failed to add '$($m.DisplayName)' ($($m.Id)): $msg" -Level Error }
                        }
                    }
                }
            }
        }
    }

    # =====================================================================
    # Phase 5 - Restore private/shared channel membership
    # =====================================================================
    if ($channelSnapshot.Count -gt 0) {
        if (-not (Confirm-Step -Message "Verify and restore $($channelSnapshot.Count) membership(s) across $($targetChannels.Count) private/shared channel(s)?")) {
            Write-Log 'Channel restore skipped by operator. Use the channel snapshot CSV to restore manually.' -Level Warning
        } else {
            # Build the work list: snapshot entries that are no longer direct channel members
            $pending = [System.Collections.Generic.List[object]]::new()
            foreach ($channel in $targetChannels) {
                $current = [System.Collections.Generic.HashSet[string]]::new(
                    [string[]]@(Get-ChannelMemberSnapshot -TeamId $groupId -Channel $channel | ForEach-Object UserId))
                foreach ($entry in $channelSnapshot | Where-Object ChannelId -eq $channel.id) {
                    if ($current.Contains($entry.UserId)) {
                        $results.Add([PSCustomObject]@{ Scope = 'Channel'; Channel = $entry.ChannelName; Id = $entry.UserId; DisplayName = $entry.DisplayName; Result = 'AlreadyPresent'; Detail = $entry.Roles })
                    } else {
                        $pending.Add($entry)
                    }
                }
            }
            Write-Log "$($pending.Count) channel membership(s) need to be restored."

            # Retry in passes: private channel members must already be team members, and Teams can lag behind Entra ID
            for ($pass = 0; $pass -le $ChannelRetryCount -and $pending.Count -gt 0; $pass++) {
                if ($pass -gt 0) {
                    Write-Log "Retry pass $pass of $ChannelRetryCount for $($pending.Count) channel membership(s) in $ChannelRetryDelaySeconds second(s)..." -Level Warning
                    Start-Sleep -Seconds $ChannelRetryDelaySeconds
                }
                $failed = [System.Collections.Generic.List[object]]::new()
                foreach ($entry in $pending) {
                    # Only "owner" or empty is accepted when adding; "guest" is assigned by the service
                    $roles = @($entry.Roles -split ';' | Where-Object { $_ -eq 'owner' })
                    $memberBody = @{
                        '@odata.type'     = '#microsoft.graph.aadUserConversationMember'
                        roles             = $roles
                        'user@odata.bind' = "https://graph.microsoft.com/v1.0/users('$($entry.UserId)')"
                    }
                    if ($entry.TenantId -and $entry.TenantId -ne $homeTenantId) { $memberBody.tenantId = $entry.TenantId }

                    try {
                        Invoke-MgGraphRequest -Method POST -Uri "v1.0/teams/$groupId/channels/$($entry.ChannelId)/members" `
                            -Body ($memberBody | ConvertTo-Json -Depth 3) -ContentType 'application/json' | Out-Null
                        $results.Add([PSCustomObject]@{ Scope = 'Channel'; Channel = $entry.ChannelName; Id = $entry.UserId; DisplayName = $entry.DisplayName; Result = 'Added'; Detail = $entry.Roles })
                        Write-Log "Added '$($entry.DisplayName)' to channel '$($entry.ChannelName)'$(if ($roles) { ' as owner' })."
                    } catch {
                        if ((Get-GraphErrorStatus $_) -eq 409 -or $_.Exception.Message -match 'Conflict') {
                            $results.Add([PSCustomObject]@{ Scope = 'Channel'; Channel = $entry.ChannelName; Id = $entry.UserId; DisplayName = $entry.DisplayName; Result = 'AlreadyPresent'; Detail = $entry.Roles })
                        } else {
                            $entry | Add-Member -NotePropertyName LastError -NotePropertyValue $_.Exception.Message -Force
                            $failed.Add($entry)
                        }
                    }
                }
                $pending = $failed
            }

            foreach ($entry in $pending) {
                Write-Log "Failed to restore '$($entry.DisplayName)' in channel '$($entry.ChannelName)': $($entry.LastError)" -Level Error
                $results.Add([PSCustomObject]@{ Scope = 'Channel'; Channel = $entry.ChannelName; Id = $entry.UserId; DisplayName = $entry.DisplayName; Result = 'Failed'; Detail = $entry.LastError })
            }
        }
    }

    # =====================================================================
    # Phase 6 - Final verification
    # =====================================================================
    Write-Log 'Verifying final group membership...'
    $finalIds = [System.Collections.Generic.HashSet[string]]::new(
        [string[]]@(Get-GroupMemberSnapshot -GroupId $groupId | ForEach-Object Id))
    $stillMissing = @($memberSnapshot | Where-Object { -not $finalIds.Contains($_.Id) })
    if ($stillMissing.Count -eq 0) {
        Write-Log "All $($memberSnapshot.Count) snapshot member(s) are present ($($finalIds.Count) total member(s))."
    } else {
        Write-Log "$($stillMissing.Count) snapshot member(s) are still missing from the group. See the results CSV." -Level Error
    }

    $channelFailures = @($results | Where-Object { $_.Scope -eq 'Channel' -and $_.Result -eq 'Failed' }).Count
    if ($channelFailures -gt 0) {
        Write-Log "$channelFailures channel membership(s) could not be restored. Re-run the adds later from the channel snapshot CSV." -Level Warning
    }
    if ($isTeam) {
        Write-Log 'Teams can take time to reflect group membership changes; confirm the roster in the Teams admin center.' -Level Warning
    }
    if ($isVivaEngage) {
        Write-Log 'Viva Engage community membership syncs from the group; confirm the community roster in Viva Engage.' -Level Warning
    }

} catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" -Level Error
} finally {
    if ($results.Count -gt 0) {
        $resultCsv = Join-Path $PSScriptRoot "${scriptName}_${safeName}_Results_$timestamp.csv"
        $results | Export-Csv -Path $resultCsv -NoTypeInformation -Encoding UTF8
        Write-Log "Results exported to: $resultCsv"
    }
    if ($connected) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Log 'Disconnected from Microsoft Graph.'
    }
}

Write-Log 'Script completed.'
