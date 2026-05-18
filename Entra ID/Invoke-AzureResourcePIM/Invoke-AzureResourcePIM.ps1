#Requires -Version 7.0
#Requires -Modules Az.Accounts

<#
.SYNOPSIS
    Lists and activates eligible Azure Resource PIM role assignments interactively,
    across management groups, subscriptions, resource groups, and individual resources.

.DESCRIPTION
    Authenticates to Azure using an interactive browser login, which supports modern
    authentication methods including FIDO2 security keys, Windows Hello, and MFA.

    Scans the requested Azure RBAC scopes for eligible PIM role assignments and
    provides an interactive menu to activate individual roles or all eligible roles
    in a single step. Supports four scope levels via dedicated switches:

      -ManagementGroup   Management group scope
      -Subscription      Subscription scope (default when no scope switch is given)
      -ResourceGroup     Resource group scope
      -Resource          Individual Azure resource scope

    Switches may be combined freely. Active vs eligible state is checked on every
    refresh so the list always reflects current status. Duplicate assignments returned
    by overlapping scope queries are automatically suppressed.

.PARAMETER Justification
    Business justification for the PIM activation request. Required by PIM policy.

.PARAMETER Duration
    Requested activation duration in ISO 8601 format. Default is 'PT8H' (8 hours).
    Policy maximums are enforced server-side; requests exceeding the cap will be
    rejected with a descriptive error.

.PARAMETER TenantId
    Entra tenant ID to authenticate against a specific tenant. Useful in multi-tenant
    environments.

.PARAMETER ManagementGroup
    Scan eligible PIM assignments at management group scope. When specified without
    -ManagementGroupId, all accessible management groups are enumerated.

.PARAMETER ManagementGroupId
    One or more management group IDs to limit the management group scan.
    Implies -ManagementGroup when used without the switch.

.PARAMETER Subscription
    Scan eligible PIM assignments at subscription scope. When specified without
    -SubscriptionId, all accessible subscriptions are enumerated. This is the
    default behavior when no scope switch is provided.

.PARAMETER SubscriptionId
    One or more subscription IDs to limit the subscription scan. Implies -Subscription.
    Also used by -ResourceGroup to determine which subscriptions to search within.

.PARAMETER ResourceGroup
    Scan eligible PIM assignments at resource group scope. Enumerates all resource
    groups across accessible (or -SubscriptionId-specified) subscriptions unless
    -ResourceGroupName is also provided.

.PARAMETER ResourceGroupName
    One or more resource group names to limit the resource group scan. Implies
    -ResourceGroup. Use with -SubscriptionId to restrict to specific subscriptions.

.PARAMETER Resource
    Scan eligible PIM assignments at individual Azure resource scope.
    Requires -ResourceId.

.PARAMETER ResourceId
    One or more full ARM resource IDs to scan at resource scope. Implies -Resource.

.EXAMPLE
    .\Invoke-AzureResourcePIM.ps1 -Justification "Investigating production incident"
    # Default: scans all accessible subscriptions.

.EXAMPLE
    .\Invoke-AzureResourcePIM.ps1 -Justification "Deployment" -Duration "PT4H" `
        -Subscription -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\Invoke-AzureResourcePIM.ps1 -Justification "MG admin" -ManagementGroup `
        -ManagementGroupId "mg-platform" -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\Invoke-AzureResourcePIM.ps1 -Justification "RG access" -ResourceGroup `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ResourceGroupName "rg-production", "rg-staging"

.EXAMPLE
    .\Invoke-AzureResourcePIM.ps1 -Justification "VM access" -Resource `
        -ResourceId "/subscriptions/xxxx/resourceGroups/rg-prod/providers/Microsoft.Compute/virtualMachines/vm01"

.EXAMPLE
    .\Invoke-AzureResourcePIM.ps1 -Justification "Full sweep" `
        -ManagementGroup -Subscription -ResourceGroup

.NOTES
    Author  : Michael Wang
    Version : 2.0
    Date    : 2026-04-25
    Module  : Az.Accounts — Install with: Install-Module Az -Scope CurrentUser
    API     : Azure ARM REST API version 2020-10-01
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Justification,

    [string]$Duration = "PT8H",

    [string]$TenantId,

    # ---- Scope switches ----
    [switch]$ManagementGroup,
    [string[]]$ManagementGroupId,

    [switch]$Subscription,
    [string[]]$SubscriptionId,

    [switch]$ResourceGroup,
    [string[]]$ResourceGroupName,

    [switch]$Resource,
    [string[]]$ResourceId
)

# ---- Configuration ----
$ScriptFolder  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Timestamp     = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile       = Join-Path $ScriptFolder "Invoke-AzureResourcePIM_$Timestamp.log"
$CsvOutput     = Join-Path $ScriptFolder "Invoke-AzureResourcePIM_Results_$Timestamp.csv"
$ArmApiVersion = "2020-10-01"

$script:RoleDefinitionCache   = @{}
$script:SubscriptionNameCache = @{}

# ---- Logging ----
function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level,

        [Parameter(Mandatory)]
        [string]$Message
    )

    $Color = switch ($Level) {
        "Info"    { "Green" }
        "Warning" { "Yellow" }
        "Error"   { "Red" }
    }

    $Entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    # Write-Host is intentional: interactive script with console as the primary UI.
    # All entries are also persisted to $LogFile for audit and capture purposes.
    Write-Host $Entry -ForegroundColor $Color
    $Entry | Out-File -FilePath $LogFile -Append -Encoding utf8
}

# ---- ARM REST Helper ----
function Invoke-ArmRequest {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory)]
        [string]$Uri,

        [string]$Method = "GET",

        [object]$Body
    )

    $Params = @{
        Uri    = $Uri
        Method = $Method
    }
    if ($null -ne $Body) {
        $Params["Payload"] = ($Body | ConvertTo-Json -Depth 20 -Compress)
    }

    $Response = Invoke-AzRestMethod @Params -ErrorAction Stop

    if ($Response.StatusCode -lt 200 -or $Response.StatusCode -ge 300) {
        $ErrObj = $Response.Content | ConvertFrom-Json -ErrorAction SilentlyContinue
        $ErrMsg = if ($null -ne $ErrObj -and $null -ne $ErrObj.error -and $null -ne $ErrObj.error.message) {
            $ErrObj.error.message
        } else {
            "HTTP $($Response.StatusCode)"
        }
        throw $ErrMsg
    }

    return ($Response.Content | ConvertFrom-Json -Depth 20)
}

# ---- Role Name Resolver ----
function Resolve-RoleDefinitionName {
    param (
        [Parameter(Mandatory)]
        [string]$RoleDefinitionId
    )

    if ($script:RoleDefinitionCache.ContainsKey($RoleDefinitionId)) {
        return $script:RoleDefinitionCache[$RoleDefinitionId]
    }

    try {
        # RoleDefinitionId is a full ARM path, e.g.:
        # /subscriptions/{sub}/providers/Microsoft.Authorization/roleDefinitions/{guid}
        # /providers/Microsoft.Authorization/roleDefinitions/{guid}  (built-in)
        $Path   = $RoleDefinitionId.TrimStart('/')
        $Uri    = "https://management.azure.com/$Path`?api-version=2022-04-01"
        $Result = Invoke-ArmRequest -Uri $Uri
        $Name   = $Result.properties.roleName
        $script:RoleDefinitionCache[$RoleDefinitionId] = $Name
        return $Name
    }
    catch {
        # Fall back to the GUID portion of the ID so the display is still readable
        $Fallback = ($RoleDefinitionId -split '/')[-1]
        $script:RoleDefinitionCache[$RoleDefinitionId] = $Fallback
        return $Fallback
    }
}

# ---- Scope Display Formatter ----
# Converts an ARM scope path to a concise, human-readable label using the
# subscription name cache for any subscription segment.
function Format-ScopeDisplay {
    param (
        [Parameter(Mandatory)]
        [string]$Scope
    )

    # Management group
    if ($Scope -match '/providers/Microsoft\.Management/managementGroups/([^/]+)$') {
        return "MG: $($Matches[1])"
    }

    # Resolve subscription name from cache when the scope is under a subscription
    $SubName = ""
    if ($Scope -match '^/subscriptions/([^/]+)') {
        $SubId   = $Matches[1]
        $SubName = if ($script:SubscriptionNameCache.ContainsKey($SubId)) {
            $script:SubscriptionNameCache[$SubId]
        } else {
            $SubId
        }
    }

    # Subscription level
    if ($Scope -match '^/subscriptions/[^/]+$') {
        return "Sub: $SubName"
    }

    # Individual resource (providers path beneath a resource group)
    if ($Scope -match '/resourceGroups/[^/]+/providers/.+/([^/]+)$') {
        return "Resource: $($Matches[1])"
    }

    # Resource group
    if ($Scope -match '/resourceGroups/([^/]+)$') {
        return "RG: $($Matches[1])"
    }

    return $Scope
}

# ---- Scope Context ----
# Returns the subscription name for any scope that lives under a subscription,
# or an empty string for management group scopes.
function Get-ScopeContext {
    param (
        [Parameter(Mandatory)]
        [string]$Scope
    )

    if ($Scope -match '^/subscriptions/([^/]+)') {
        $SubId = $Matches[1]
        return if ($script:SubscriptionNameCache.ContainsKey($SubId)) {
            $script:SubscriptionNameCache[$SubId]
        } else {
            $SubId
        }
    }
    return ""
}

# ---- Main Execution ----
try {
    Write-Log -Level Info -Message "Starting Invoke-AzureResourcePIM..."

    if (-not (Get-Module -ListAvailable "Az.Accounts" -ErrorAction SilentlyContinue)) {
        throw "Az.Accounts module not found. Install with: Install-Module Az -Scope CurrentUser"
    }

    # Resolve effective scope flags; providing an ID parameter implies its switch
    $ScanMG  = $ManagementGroup.IsPresent -or ($ManagementGroupId -and $ManagementGroupId.Count -gt 0)
    $ScanSub = $Subscription.IsPresent    -or ($SubscriptionId    -and $SubscriptionId.Count    -gt 0)
    $ScanRG  = $ResourceGroup.IsPresent   -or ($ResourceGroupName -and $ResourceGroupName.Count -gt 0)
    $ScanRes = $Resource.IsPresent        -or ($ResourceId        -and $ResourceId.Count        -gt 0)

    # Default: scan all subscriptions when no scope switch is provided
    if (-not ($ScanMG -or $ScanSub -or $ScanRG -or $ScanRes)) {
        $ScanSub = $true
    }

    if ($ScanRes -and (-not $ResourceId -or $ResourceId.Count -eq 0)) {
        throw "-Resource scope requires at least one -ResourceId value."
    }

    # Interactive browser login — supports FIDO2, Windows Hello, and MFA
    Write-Log -Level Info -Message "Connecting to Azure (interactive browser login)..."
    $ConnectParams = @{}
    if ($TenantId) { $ConnectParams["TenantId"] = $TenantId }
    Connect-AzAccount @ConnectParams -ErrorAction Stop | Out-Null

    $Context = Get-AzContext
    if (-not $Context) {
        throw "Authentication succeeded but no Azure context was established."
    }
    Write-Log -Level Info -Message "Authenticated as: $($Context.Account.Id) | Tenant: $($Context.Tenant.Id)"

    # ---- Build Scope Targets ----
    # Each target holds the ARM scope path queried for PIM eligible assignments.
    $ScopeTargets = [System.Collections.Generic.List[PSObject]]::new()

    # Management group targets
    if ($ScanMG) {
        if ($ManagementGroupId -and $ManagementGroupId.Count -gt 0) {
            foreach ($MgId in $ManagementGroupId) {
                try {
                    $MgUri   = "https://management.azure.com/providers/Microsoft.Management/managementGroups/$MgId`?api-version=2020-02-01"
                    $MgInfo  = Invoke-ArmRequest -Uri $MgUri
                    $MgLabel = if ($null -ne $MgInfo.properties.displayName) { $MgInfo.properties.displayName } else { $MgId }
                } catch {
                    $MgLabel = $MgId
                }
                $ScopeTargets.Add([PSCustomObject]@{
                    ScopeType = "ManagementGroup"
                    ScopePath = "/providers/Microsoft.Management/managementGroups/$MgId"
                    Label     = $MgLabel
                })
            }
        } else {
            Write-Log -Level Info -Message "Enumerating accessible management groups..."
            try {
                $MgListUri = "https://management.azure.com/providers/Microsoft.Management/managementGroups?api-version=2020-02-01"
                $MgList    = (Invoke-ArmRequest -Uri $MgListUri).value
                foreach ($Mg in $MgList) {
                    $MgLabel = if ($null -ne $Mg.properties -and $null -ne $Mg.properties.displayName) {
                        $Mg.properties.displayName
                    } else {
                        $Mg.name
                    }
                    $ScopeTargets.Add([PSCustomObject]@{
                        ScopeType = "ManagementGroup"
                        ScopePath = "/providers/Microsoft.Management/managementGroups/$($Mg.name)"
                        Label     = $MgLabel
                    })
                }
                Write-Log -Level Info -Message "Found $($MgList.Count) management group(s)."
            } catch {
                Write-Log -Level Warning -Message "Failed to enumerate management groups: $($_.Exception.Message)"
            }
        }
    }

    # Subscription targets — also builds the SubscriptionNameCache used by RG/Resource display
    # $SubsForRG holds subscription objects available for the resource group enumeration step.
    $SubsForRG = $null
    if ($ScanSub -or $ScanRG) {
        if ($SubscriptionId -and $SubscriptionId.Count -gt 0) {
            $SubsForRG = foreach ($SubId in $SubscriptionId) {
                $Sub = Get-AzSubscription -SubscriptionId $SubId -ErrorAction Stop
                $script:SubscriptionNameCache[$Sub.Id] = $Sub.Name
                if ($ScanSub) {
                    $ScopeTargets.Add([PSCustomObject]@{
                        ScopeType = "Subscription"
                        ScopePath = "/subscriptions/$($Sub.Id)"
                        Label     = $Sub.Name
                    })
                }
                [PSCustomObject]@{ Id = $Sub.Id; Name = $Sub.Name }
            }
        } else {
            Write-Log -Level Info -Message "Enumerating accessible subscriptions..."
            $AllSubs = Get-AzSubscription -ErrorAction Stop
            $SubsForRG = foreach ($Sub in $AllSubs) {
                $script:SubscriptionNameCache[$Sub.Id] = $Sub.Name
                if ($ScanSub) {
                    $ScopeTargets.Add([PSCustomObject]@{
                        ScopeType = "Subscription"
                        ScopePath = "/subscriptions/$($Sub.Id)"
                        Label     = $Sub.Name
                    })
                }
                [PSCustomObject]@{ Id = $Sub.Id; Name = $Sub.Name }
            }
            Write-Log -Level Info -Message "Found $(@($AllSubs).Count) subscription(s)."
        }
    }

    # Resource group targets — uses ARM API to avoid changing Az context
    if ($ScanRG) {
        $RgSubs = @($SubsForRG)
        if ($RgSubs.Count -eq 0) {
            Write-Log -Level Warning -Message "No subscriptions available for resource group enumeration."
        } else {
            foreach ($Sub in $RgSubs) {
                if ($ResourceGroupName -and $ResourceGroupName.Count -gt 0) {
                    foreach ($RgName in $ResourceGroupName) {
                        $ScopeTargets.Add([PSCustomObject]@{
                            ScopeType = "ResourceGroup"
                            ScopePath = "/subscriptions/$($Sub.Id)/resourceGroups/$RgName"
                            Label     = "$RgName ($($Sub.Name))"
                        })
                    }
                } else {
                    Write-Log -Level Info -Message "Enumerating resource groups in '$($Sub.Name)'..."
                    try {
                        $RgListUri = "https://management.azure.com/subscriptions/$($Sub.Id)/resourcegroups?api-version=2021-04-01"
                        $RgList    = (Invoke-ArmRequest -Uri $RgListUri).value
                        foreach ($Rg in $RgList) {
                            $ScopeTargets.Add([PSCustomObject]@{
                                ScopeType = "ResourceGroup"
                                ScopePath = "/subscriptions/$($Sub.Id)/resourceGroups/$($Rg.name)"
                                Label     = "$($Rg.name) ($($Sub.Name))"
                            })
                        }
                        Write-Log -Level Info -Message "  Found $($RgList.Count) resource group(s) in '$($Sub.Name)'."
                    } catch {
                        Write-Log -Level Warning -Message "Failed to enumerate RGs in '$($Sub.Name)': $($_.Exception.Message)"
                    }
                }
            }
        }
    }

    # Individual resource targets
    if ($ScanRes) {
        foreach ($ResId in $ResourceId) {
            $ResName = ($ResId -split '/')[-1]
            # Pre-populate the subscription name cache for cleaner scope display
            if ($ResId -match '^/subscriptions/([^/]+)') {
                $SubIdFromRes = $Matches[1]
                if (-not $script:SubscriptionNameCache.ContainsKey($SubIdFromRes)) {
                    try {
                        $Sub = Get-AzSubscription -SubscriptionId $SubIdFromRes -ErrorAction SilentlyContinue
                        if ($Sub) { $script:SubscriptionNameCache[$SubIdFromRes] = $Sub.Name }
                    } catch {}
                }
            }
            $ScopeTargets.Add([PSCustomObject]@{
                ScopeType = "Resource"
                ScopePath = $ResId
                Label     = $ResName
            })
        }
    }

    if ($ScopeTargets.Count -eq 0) {
        throw "No scope targets could be resolved from the provided parameters."
    }

    $ScopeTypeSummary = ($ScopeTargets | Group-Object ScopeType |
        ForEach-Object { "$($_.Count) $($_.Name)(s)" }) -join ", "
    Write-Log -Level Info -Message "Scope targets: $ScopeTypeSummary"

    $SessionResults = [System.Collections.Generic.List[PSObject]]::new()

    # ---- Interactive Menu Loop ----
    while ($true) {
        Clear-Host
        Write-Host "================================================================" -ForegroundColor Cyan
        Write-Host "         Azure Resource PIM Activation Tool" -ForegroundColor Cyan
        Write-Host "================================================================" -ForegroundColor Cyan
        Write-Host "Account  : $($Context.Account.Id)"
        Write-Host "Tenant   : $($Context.Tenant.Id)"
        Write-Host "Duration : $Duration"
        Write-Host "Scopes   : $ScopeTypeSummary"
        Write-Host ""

        # ---- Fetch Eligible Assignments ----
        $AllEligible = [System.Collections.Generic.List[PSObject]]::new()
        # Track unique role+scope pairs to suppress duplicates from overlapping queries
        $SeenKeys    = [System.Collections.Generic.HashSet[string]]::new()

        $TargetList  = @($ScopeTargets)
        $TargetTotal = $TargetList.Count
        $TargetDone  = 0

        foreach ($Target in $TargetList) {
            $TargetDone++
            Write-Progress -Activity "Scanning for eligible PIM assignments" `
                -Status "[$TargetDone/$TargetTotal] [$($Target.ScopeType)] $($Target.Label)" `
                -PercentComplete (($TargetDone / $TargetTotal) * 100)

            try {
                $ScopeTrimmed = $Target.ScopePath.TrimStart('/')
                $EligUri      = "https://management.azure.com/$ScopeTrimmed/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=$ArmApiVersion&`$filter=asTarget()"
                $EligItems    = (Invoke-ArmRequest -Uri $EligUri).value

                $ActiveUri   = "https://management.azure.com/$ScopeTrimmed/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=$ArmApiVersion&`$filter=asTarget()"
                $ActiveItems = try { (Invoke-ArmRequest -Uri $ActiveUri).value } catch { @() }

                # Build a lookup set for O(1) active-state checks
                $ActiveKeys = @{}
                foreach ($Active in $ActiveItems) {
                    $K = "$($Active.properties.roleDefinitionId)|$($Active.properties.scope)"
                    $ActiveKeys[$K] = $true
                }

                foreach ($Item in $EligItems) {
                    $Props   = $Item.properties
                    $DedupeK = "$($Props.roleDefinitionId)|$($Props.scope)"

                    # Skip if already captured from an overlapping scope query
                    if (-not $SeenKeys.Add($DedupeK)) { continue }

                    $AllEligible.Add([PSCustomObject]@{
                        ScopeType        = $Target.ScopeType
                        Scope            = $Props.scope
                        RoleDefinitionId = $Props.roleDefinitionId
                        PrincipalId      = $Props.principalId
                        IsActive         = $ActiveKeys.ContainsKey($DedupeK)
                        Index            = 0
                        RoleName         = $null
                        ScopeDisplay     = $null
                        ScopeContext     = $null
                    })
                }
            }
            catch {
                Write-Log -Level Warning -Message "[$($Target.ScopeType)] '$($Target.Label)': $($_.Exception.Message)"
            }
        }
        Write-Progress -Activity "Scanning for eligible PIM assignments" -Completed

        if ($AllEligible.Count -eq 0) {
            Write-Log -Level Warning -Message "No eligible Azure Resource PIM assignments found."
            Write-Host ""
            Write-Host "Press any key to exit..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            break
        }

        # ---- Resolve Role Names and Build Display Metadata ----
        $TotalItems = $AllEligible.Count
        $ItemsDone  = 0
        foreach ($Item in $AllEligible) {
            $ItemsDone++
            Write-Progress -Activity "Resolving role definition names" `
                -Status "$ItemsDone of $TotalItems" `
                -PercentComplete (($ItemsDone / $TotalItems) * 100)
            $Item.Index        = $ItemsDone
            $Item.RoleName     = Resolve-RoleDefinitionName -RoleDefinitionId $Item.RoleDefinitionId
            $Item.ScopeDisplay = Format-ScopeDisplay -Scope $Item.Scope
            $Item.ScopeContext = Get-ScopeContext -Scope $Item.Scope
        }
        Write-Progress -Activity "Resolving role definition names" -Completed

        # ---- Display Table ----
        Write-Host "Eligible Azure Resource PIM Assignments:" -ForegroundColor Green
        Write-Host ""
        $AllEligible | Format-Table `
            @{ Label = '#';       Expression = { $_.Index };                                            Width = 4  },
            @{ Label = 'Role';    Expression = { $_.RoleName };                                         Width = 35 },
            @{ Label = 'Scope';   Expression = { $_.ScopeDisplay };                                    Width = 32 },
            @{ Label = 'Context'; Expression = { $_.ScopeContext };                                    Width = 22 },
            @{ Label = 'Status';  Expression = { if ($_.IsActive) { 'Active' } else { 'Eligible' } }; Width = 10 } `
            -Wrap

        Write-Host ""
        Write-Host "Options:" -ForegroundColor Cyan
        Write-Host "  [1-$TotalItems]  Activate a specific role"
        Write-Host "  [A]         Activate ALL eligible (inactive) roles"
        Write-Host "  [R]         Refresh the list"
        Write-Host "  [Q]         Quit"
        Write-Host ""

        $Choice      = Read-Host "Select an option"
        $ChoiceUpper = $Choice.ToUpper().Trim()

        if ($ChoiceUpper -eq 'Q') {
            Write-Log -Level Info -Message "User exited the menu."
            break
        }
        elseif ($ChoiceUpper -eq 'R') {
            continue
        }
        elseif ($ChoiceUpper -eq 'A') {
            $ToActivate = @($AllEligible | Where-Object { -not $_.IsActive })
            if ($ToActivate.Count -eq 0) {
                Write-Log -Level Warning -Message "All eligible assignments are already active."
                Start-Sleep -Seconds 2
                continue
            }

            Write-Host ""
            $Confirm = Read-Host "About to activate $($ToActivate.Count) role(s). Confirm? (Y/N)"
            if ($Confirm -notmatch '^[Yy]$') {
                Write-Log -Level Info -Message "Bulk activation cancelled by user."
                Start-Sleep -Seconds 2
                continue
            }
        }
        elseif ($ChoiceUpper -match '^\d+$') {
            $Idx = [int]$ChoiceUpper
            if ($Idx -lt 1 -or $Idx -gt $TotalItems) {
                Write-Host "Invalid selection. Enter a number between 1 and $TotalItems." -ForegroundColor Red
                Start-Sleep -Seconds 2
                continue
            }

            $Selected = $AllEligible[$Idx - 1]
            if ($Selected.IsActive) {
                Write-Log -Level Warning -Message "'$($Selected.RoleName)' at '$($Selected.ScopeDisplay)' is already active."
                Start-Sleep -Seconds 2
                continue
            }
            $ToActivate = @($Selected)
        }
        else {
            Write-Host "Unrecognised option. Please try again." -ForegroundColor Red
            Start-Sleep -Seconds 2
            continue
        }

        # ---- Process Activations ----
        foreach ($Item in $ToActivate) {
            Write-Log -Level Info -Message "Requesting activation: '$($Item.RoleName)' on '$($Item.Scope)'..."

            $RequestName = [System.Guid]::NewGuid().ToString()
            $ScopePath   = $Item.Scope.TrimStart('/')
            $RequestUri  = "https://management.azure.com/$ScopePath/providers/Microsoft.Authorization/roleAssignmentScheduleRequests/$RequestName`?api-version=$ArmApiVersion"

            $RequestBody = @{
                properties = @{
                    principalId      = $Item.PrincipalId
                    roleDefinitionId = $Item.RoleDefinitionId
                    requestType      = "SelfActivate"
                    justification    = $Justification
                    scheduleInfo     = @{
                        startDateTime = $null
                        expiration    = @{
                            type     = "AfterDuration"
                            duration = $Duration
                        }
                    }
                }
            }

            try {
                $Response   = Invoke-ArmRequest -Uri $RequestUri -Method "PUT" -Body $RequestBody
                $ProvStatus = $Response.properties.status
                Write-Log -Level Info -Message "Request submitted — '$($Item.RoleName)': $ProvStatus"

                $SessionResults.Add([PSCustomObject]@{
                    Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    RoleName     = $Item.RoleName
                    ScopeType    = $Item.ScopeType
                    ScopeDisplay = $Item.ScopeDisplay
                    ScopeContext = $Item.ScopeContext
                    Scope        = $Item.Scope
                    Status       = $ProvStatus
                    Error        = ""
                })
            }
            catch {
                Write-Log -Level Error -Message "Failed to activate '$($Item.RoleName)': $($_.Exception.Message)"

                $SessionResults.Add([PSCustomObject]@{
                    Timestamp    = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    RoleName     = $Item.RoleName
                    ScopeType    = $Item.ScopeType
                    ScopeDisplay = $Item.ScopeDisplay
                    ScopeContext = $Item.ScopeContext
                    Scope        = $Item.Scope
                    Status       = "Failed"
                    Error        = $_.Exception.Message
                })
            }
        }

        Write-Host ""
        Write-Host "Done. Press any key to return to the menu..." -ForegroundColor Cyan
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

    # ---- Export Session Results ----
    if ($SessionResults.Count -gt 0) {
        $SessionResults | Export-Csv -Path $CsvOutput -NoTypeInformation -Encoding utf8
        Write-Log -Level Info -Message "Session results exported to: $CsvOutput"
    }
}
catch {
    Write-Log -Level Error -Message "Unhandled error: $($_.Exception.Message)"
    if ($_.ScriptStackTrace) {
        Write-Log -Level Error -Message "Stack trace:`n$($_.ScriptStackTrace)"
    }
}
finally {
    try { Disconnect-AzAccount -ErrorAction SilentlyContinue | Out-Null } catch {}
    Write-Log -Level Info -Message "Session closed. Log: $LogFile"
}
