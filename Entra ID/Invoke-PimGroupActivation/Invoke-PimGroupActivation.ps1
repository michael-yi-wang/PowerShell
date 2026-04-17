<#
.SYNOPSIS
    Connects to Entra ID and allows interactive activation of eligible PIM for Groups assignments.

.DESCRIPTION
    This script performs an interactive login to Entra ID using the Microsoft Graph PowerShell SDK. 
    It identifies eligible PIM group assignments, checks which are already active, and provides 
    an interactive menu for the user to activate specific groups or all at once.

.PARAMETER Justification
    The reason for the PIM activation.

.PARAMETER Duration
    The duration of the activation in ISO 8601 format. Default is 'PT8H' (8 hours).

.EXAMPLE
    .\Invoke-PimGroupActivation.ps1 -Justification "System administration"
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$Justification,

    [string]$Duration = "PT10H"
)

# --- Configuration & Logging ---
$ScriptFolder = Split-Path -Parent $MyInvocation.MyCommand.Path
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $ScriptFolder "Invoke-PimGroupActivation_$Timestamp.log"
$CsvOutput = Join-Path $ScriptFolder "Invoke-PimGroupActivation_Results_$Timestamp.csv"

function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level,
        
        [Parameter(Mandatory = $true)]
        [string]$Message
    )
    
    $Color = switch ($Level) {
        "Info" { "Green" }
        "Warning" { "Yellow" }
        "Error" { "Red" }
        Default { "White" }
    }
    
    $LogEntry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Write-Host $LogEntry -ForegroundColor $Color
    $LogEntry | Out-File -FilePath $LogFile -Append
}

# --- Main Execution ---
try {
    Write-Log -Level Info -Message "Starting Interactive PIM Group Activation..."

    # Check for required modules
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Identity.Governance)) {
        throw "Microsoft.Graph.Identity.Governance module is required. Please install it using 'Install-Module Microsoft.Graph'."
    }

    # Authentication
    Write-Log -Level Info -Message "Connecting to Entra ID (Interactive Login)..."
    $Scopes = @(
        "PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup", 
        "PrivilegedAssignmentSchedule.Read.AzureADGroup",
        "PrivilegedEligibilitySchedule.Read.AzureADGroup",
        "PrivilegedAccess.Read.AzureADGroup",
        "Directory.Read.All"
    )
    Connect-MgGraph -Scopes $Scopes | Out-Null

    # Get Current User ID
    $MgContext = Get-MgContext
    if (-not $MgContext) {
        throw "Failed to retrieve Microsoft Graph context. Please ensure you are logged in."
    }
    
    $CurrentUser = Get-MgUser -UserId $MgContext.Account
    $PrincipalId = $CurrentUser.Id
    Write-Log -Level Info -Message "Authenticated as $($MgContext.Account) (ID: $PrincipalId)"

    $Results = [System.Collections.Generic.List[PSObject]]::new()

    while ($true) {
        Clear-Host
        Write-Host "--- Entra ID PIM for Groups Activation Menu ---" -ForegroundColor Cyan
        Write-Host "User: $($MgContext.Account)"
        Write-Host ""

        # Retrieve Eligible and Active Assignments
        Write-Log -Level Info -Message "Refreshing PIM assignment status..."
        $Eligibilities = Get-MgIdentityGovernancePrivilegedAccessGroupEligibilityScheduleInstance -Filter "principalId eq '$PrincipalId'"
        $ActiveAssignments = Invoke-MgFilterIdentityGovernancePrivilegedAccessGroupAssignmentScheduleInstanceByCurrentUser -On "principal"

        if ($null -eq $Eligibilities -or $Eligibilities.Count -eq 0) {
            Write-Log -Level Warning -Message "No eligible group assignments found."
            Write-Host "Press any key to exit..."
            $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
            break
        }

        # Build Display List
        $DisplayList = [System.Collections.Generic.List[PSObject]]::new()
        foreach ($Eligible in $Eligibilities) {
            $IsActive = $null -ne ($ActiveAssignments | Where-Object { $_.GroupId -eq $Eligible.GroupId -and $_.AccessId -eq $Eligible.AccessId })
            
            # Get Group Name
            $GroupName = try { (Get-MgGroup -GroupId $Eligible.GroupId).DisplayName } catch { $Eligible.GroupId }

            $DisplayList.Add([PSCustomObject]@{
                    Index     = $DisplayList.Count + 1
                    GroupName = $GroupName
                    Access    = $Eligible.AccessId
                    Status    = if ($IsActive) { "Already Active" } else { "Eligible" }
                    GroupId   = $Eligible.GroupId
                    AccessId  = $Eligible.AccessId
                })
        }

        # Show Table
        $DisplayList | Format-Table Index, GroupName, Access, Status -AutoSize

        Write-Host "Options:"
        Write-Host " [1-$($DisplayList.Count)] Activate specific group"
        Write-Host " [A] Activate ALL eligible groups"
        Write-Host " [R] Refresh list"
        Write-Host " [Q] Quit"
        Write-Host ""
        $Choice = Read-Host "Select an option"

        if ($Choice -eq 'Q') {
            break
        }
        elseif ($Choice -eq 'R') {
            continue
        }
        elseif ($Choice -eq 'A') {
            $ToActivate = $DisplayList | Where-Object { $_.Status -eq "Eligible" }
            if ($ToActivate.Count -eq 0) {
                Write-Log -Level Info -Message "No eligible groups to activate."
                Start-Sleep -Seconds 2
                continue
            }
            Write-Log -Level Info -Message "Activating all eligible groups..."
        }
        elseif ($Choice -match '^\d+$' -and [int]$Choice -ge 1 -and [int]$Choice -le $DisplayList.Count) {
            $Selected = $DisplayList[[int]$Choice - 1]
            if ($Selected.Status -eq "Already Active") {
                Write-Log -Level Warning -Message "Group '$($Selected.GroupName)' is already active."
                Start-Sleep -Seconds 2
                continue
            }
            $ToActivate = @($Selected)
        }
        else {
            Write-Host "Invalid selection. Try again." -ForegroundColor Red
            Start-Sleep -Seconds 2
            continue
        }

        # Process Activations
        foreach ($Item in $ToActivate) {
            Write-Log -Level Info -Message "Activating '$($Item.GroupName)' ($($Item.Access))..."
            
            $Params = @{
                AccessId      = $Item.AccessId
                PrincipalId   = $PrincipalId
                GroupId       = $Item.GroupId
                Action        = "selfActivate"
                Justification = $Justification
                ScheduleInfo  = @{
                    StartDateTime = [System.DateTime]::UtcNow
                    Expiration    = @{
                        Type     = "afterDuration"
                        Duration = $Duration
                    }
                }
            }

            try {
                $Request = New-MgIdentityGovernancePrivilegedAccessGroupAssignmentScheduleRequest -BodyParameter $Params
                Write-Log -Level Info -Message "Activation request submitted for '$($Item.GroupName)'. Status: $($Request.Status)"
                
                $Results.Add([PSCustomObject]@{
                        Timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        GroupName  = $Item.GroupName
                        GroupId    = $Item.GroupId
                        AccessType = $Item.AccessId
                        Status     = $Request.Status
                        Error      = ""
                    })
            }
            catch {
                Write-Log -Level Error -Message "Failed to activate '$($Item.GroupName)': $($_.Exception.Message)"
                $Results.Add([PSCustomObject]@{
                        Timestamp  = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        GroupName  = $Item.GroupName
                        GroupId    = $Item.GroupId
                        AccessType = $Item.AccessId
                        Status     = "Failed"
                        Error      = $_.Exception.Message
                    })
            }
        }
        
        Write-Host "Done. Press any key to return to menu..."
        $null = $Host.UI.RawUI.ReadKey("NoEcho,IncludeKeyDown")
    }

    # Final Export
    if ($Results.Count -gt 0) {
        $Results | Export-Csv -Path $CsvOutput -NoTypeInformation -Encoding utf8
        Write-Log -Level Info -Message "Session results exported to: $CsvOutput"
    }

}
catch {
    Write-Log -Level Error -Message "An unhandled error occurred: $($_.Exception.Message)"
}
finally {
    Write-Log -Level Info -Message "Interactive session closed. Log: $LogFile"
}
