#Requires -Version 7.0
#Requires -Modules Az.Accounts

<#
.SYNOPSIS
    Lists and activates eligible Azure Resource PIM role assignments interactively.

.DESCRIPTION
    Authenticates to Azure using an interactive browser login, which supports modern
    authentication methods including FIDO2 security keys, Windows Hello, and MFA.

    Scans all accessible subscriptions (or a specified subset) for eligible PIM Azure
    RBAC role assignments and provides an interactive menu to activate individual roles
    or all eligible roles in a single step.

    Active vs eligible state is checked on every refresh so the list always reflects
    current status.

.PARAMETER Justification
    Business justification for the PIM activation request. Required by PIM policy.

.PARAMETER Duration
    Requested activation duration in ISO 8601 format. Default is 'PT8H' (8 hours).
    Policy maximums are enforced server-side; requests exceeding the cap will be
    rejected with a descriptive error.

.PARAMETER SubscriptionId
    One or more subscription IDs to limit the search scope. If omitted, all accessible
    subscriptions are scanned.

.PARAMETER TenantId
    Entra tenant ID to authenticate against a specific tenant. Useful in multi-tenant
    environments.

.EXAMPLE
    .\Invoke-AzureResourcePIM.ps1 -Justification "Investigating production incident"

.EXAMPLE
    .\Invoke-AzureResourcePIM.ps1 -Justification "Deployment" -Duration "PT4H" `
        -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.EXAMPLE
    .\Invoke-AzureResourcePIM.ps1 -Justification "Routine admin" `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.NOTES
    Author  : Michael Wang
    Version : 1.0
    Date    : 2026-04-24
    Module  : Az.Accounts — Install with: Install-Module Az -Scope CurrentUser
    API     : Azure ARM REST API version 2020-10-01
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Justification,

    [string]$Duration = "PT8H",

    [string[]]$SubscriptionId,

    [string]$TenantId
)

# ---- Configuration ----
$ScriptFolder  = Split-Path -Parent $MyInvocation.MyCommand.Path
$Timestamp     = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile       = Join-Path $ScriptFolder "Invoke-AzureResourcePIM_$Timestamp.log"
$CsvOutput     = Join-Path $ScriptFolder "Invoke-AzureResourcePIM_Results_$Timestamp.csv"
$ArmApiVersion = "2020-10-01"

$script:RoleDefinitionCache = @{}

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
        $Path = $RoleDefinitionId.TrimStart('/')
        $Uri  = "https://management.azure.com/$Path`?api-version=2022-04-01"
        $Result = Invoke-ArmRequest -Uri $Uri
        $Name = $Result.properties.roleName
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
function Format-ScopeDisplay {
    param (
        [Parameter(Mandatory)]
        [string]$Scope,

        [Parameter(Mandatory)]
        [string]$SubscriptionName
    )

    if ($Scope -match '^/subscriptions/[^/]+$') {
        return "Sub: $SubscriptionName"
    }
    elseif ($Scope -match '/resourceGroups/([^/]+)$') {
        return "RG: $($Matches[1])"
    }
    elseif ($Scope -match '/providers/.+/([^/]+)$') {
        return "Resource: $($Matches[1])"
    }
    return $Scope
}

# ---- Main Execution ----
try {
    Write-Log -Level Info -Message "Starting Invoke-AzureResourcePIM..."

    if (-not (Get-Module -ListAvailable "Az.Accounts" -ErrorAction SilentlyContinue)) {
        throw "Az.Accounts module not found. Install with: Install-Module Az -Scope CurrentUser"
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

    # Build subscription list
    if ($SubscriptionId -and $SubscriptionId.Count -gt 0) {
        $Subscriptions = foreach ($SubId in $SubscriptionId) {
            $Sub = Get-AzSubscription -SubscriptionId $SubId -ErrorAction Stop
            [PSCustomObject]@{ Id = $Sub.Id; Name = $Sub.Name }
        }
    }
    else {
        Write-Log -Level Info -Message "Enumerating accessible subscriptions..."
        $Subscriptions = Get-AzSubscription -ErrorAction Stop | ForEach-Object {
            [PSCustomObject]@{ Id = $_.Id; Name = $_.Name }
        }
    }

    if (-not $Subscriptions -or @($Subscriptions).Count -eq 0) {
        throw "No accessible subscriptions found for account '$($Context.Account.Id)'."
    }
    Write-Log -Level Info -Message "Scanning $(@($Subscriptions).Count) subscription(s)."

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
        Write-Host ""

        # ---- Fetch Eligible Assignments ----
        $AllEligible = [System.Collections.Generic.List[PSObject]]::new()
        $SubList     = @($Subscriptions)
        $SubTotal    = $SubList.Count
        $SubDone     = 0

        foreach ($Sub in $SubList) {
            $SubDone++
            Write-Progress -Activity "Scanning for eligible PIM assignments" `
                -Status "[$SubDone/$SubTotal] $($Sub.Name)" `
                -PercentComplete (($SubDone / $SubTotal) * 100)

            try {
                # asTarget() filters results to the currently authenticated user
                $EligUri  = "https://management.azure.com/subscriptions/$($Sub.Id)/providers/Microsoft.Authorization/roleEligibilityScheduleInstances?api-version=$ArmApiVersion&`$filter=asTarget()"
                $EligItems = (Invoke-ArmRequest -Uri $EligUri).value

                # Fetch active assignments to show current state
                $ActiveUri   = "https://management.azure.com/subscriptions/$($Sub.Id)/providers/Microsoft.Authorization/roleAssignmentScheduleInstances?api-version=$ArmApiVersion&`$filter=asTarget()"
                $ActiveItems = try { (Invoke-ArmRequest -Uri $ActiveUri).value } catch { @() }

                # Build a lookup set for O(1) active-state checks
                $ActiveKeys = @{}
                foreach ($Active in $ActiveItems) {
                    $K = "$($Active.properties.roleDefinitionId)|$($Active.properties.scope)"
                    $ActiveKeys[$K] = $true
                }

                foreach ($Item in $EligItems) {
                    $Props = $Item.properties
                    $K     = "$($Props.roleDefinitionId)|$($Props.scope)"

                    $AllEligible.Add([PSCustomObject]@{
                        SubscriptionId   = $Sub.Id
                        SubscriptionName = $Sub.Name
                        Scope            = $Props.scope
                        RoleDefinitionId = $Props.roleDefinitionId
                        PrincipalId      = $Props.principalId
                        IsActive         = $ActiveKeys.ContainsKey($K)
                        Index            = 0
                        RoleName         = $null
                        ScopeDisplay     = $null
                    })
                }
            }
            catch {
                Write-Log -Level Warning -Message "Subscription '$($Sub.Name)': $($_.Exception.Message)"
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
            $Item.ScopeDisplay = Format-ScopeDisplay -Scope $Item.Scope -SubscriptionName $Item.SubscriptionName
        }
        Write-Progress -Activity "Resolving role definition names" -Completed

        # ---- Display Table ----
        Write-Host "Eligible Azure Resource PIM Assignments:" -ForegroundColor Green
        Write-Host ""
        $AllEligible | Format-Table `
            @{ Label = '#';           Expression = { $_.Index };                                 Width = 4 },
            @{ Label = 'Role';        Expression = { $_.RoleName };                              Width = 35 },
            @{ Label = 'Scope';       Expression = { $_.ScopeDisplay };                         Width = 30 },
            @{ Label = 'Subscription'; Expression = { $_.SubscriptionName };                    Width = 25 },
            @{ Label = 'Status';      Expression = { if ($_.IsActive) { 'Active' } else { 'Eligible' } }; Width = 10 } `
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
                    Timestamp        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    RoleName         = $Item.RoleName
                    ScopeDisplay     = $Item.ScopeDisplay
                    Scope            = $Item.Scope
                    SubscriptionName = $Item.SubscriptionName
                    SubscriptionId   = $Item.SubscriptionId
                    Status           = $ProvStatus
                    Error            = ""
                })
            }
            catch {
                Write-Log -Level Error -Message "Failed to activate '$($Item.RoleName)': $($_.Exception.Message)"

                $SessionResults.Add([PSCustomObject]@{
                    Timestamp        = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    RoleName         = $Item.RoleName
                    ScopeDisplay     = $Item.ScopeDisplay
                    Scope            = $Item.Scope
                    SubscriptionName = $Item.SubscriptionName
                    SubscriptionId   = $Item.SubscriptionId
                    Status           = "Failed"
                    Error            = $_.Exception.Message
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
