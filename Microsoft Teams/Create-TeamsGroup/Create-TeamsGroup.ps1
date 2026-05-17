<#
#SYNOPSIS
    Creates Microsoft Teams (Team provisioning) from a CSV file using the MicrosoftTeams PowerShell module.

#DESCRIPTION
    Creates Microsoft Teams from a CSV file using the MicrosoftTeams PowerShell module (`New-Team`, `Add-TeamUser`).

    CSV format (header required):
    TeamName,OwnerUPN

#PARAMETER CsvPath
    Path to the input CSV file containing team details.

#PARAMETER ReturnTeamsEmail
    If $true, the script attempts to return the email address for the default "General" channel for each created team.
    Note: The MicrosoftTeams module does not expose channel email addresses. If `-ReturnTeamsEmail` is supplied, the script will attempt to use the Microsoft Graph PowerShell module to fetch the General channel email. If Microsoft.Graph is not available the script will return a message explaining the requirement.

#NOTES
    - This version uses the MicrosoftTeams PowerShell module. Ensure it is installed and up-to-date:
        Install-Module MicrosoftTeams -Scope CurrentUser
    - The script requires permissions to create teams and add owners in your tenant.
    - The script creates Teams via `New-Team` and assigns the owner via `Add-TeamUser -Role Owner`.
#>
[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,
    
    [Parameter(Mandatory = $false)]
    [bool]$ReturnTeamsEmail = $false
)


function Connect-Teams {
    try {
        # Connect using MicrosoftTeams module. Prefer Connect-MicrosoftTeams interactive auth.
        if (-not (Get-Module -ListAvailable -Name MicrosoftTeams)) {
            Write-Warning "MicrosoftTeams module not found. Install it with: Install-Module MicrosoftTeams -Scope CurrentUser"
        }

        # If already connected, Connect-MicrosoftTeams will reuse the session.
        Connect-MicrosoftTeams -ErrorAction Stop

        Write-Host "Successfully connected to Microsoft Teams" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to Microsoft Teams: $($_.Exception.Message)"
        exit 1
    }
}

function New-TeamsGroupFromCsv {
    param (
        [string]$CsvPath,
        [bool]$ReturnTeamsEmail
    )
    
    try {
        # Validate and import CSV
        if (-not (Test-Path $CsvPath)) {
            throw "CSV file not found at path: $CsvPath"
        }
        
        $teams = Import-Csv $CsvPath
        
        # Validate CSV structure
        if (-not ($teams | Get-Member -Name "TeamName" -MemberType NoteProperty) -or
            -not ($teams | Get-Member -Name "OwnerUPN" -MemberType NoteProperty)) {
            throw "CSV must contain 'TeamName' and 'OwnerUPN' columns"
        }
        
        $results = @()
        
        foreach ($team in $teams) {
            Write-Host "Processing team: $($team.TeamName)" -ForegroundColor Cyan

            try {
                # Create the Team using MicrosoftTeams' New-Team cmdlet
                # Generate a mail nickname by replacing non-alphanumeric chars with '.'
                $mailNick = ($team.TeamName -replace '[^a-zA-Z0-9]', '.')

                # New-Team will create the underlying Microsoft 365 Group + Team
                $newTeam = New-Team -DisplayName $team.TeamName -Visibility Private -MailNickName $mailNick -Owner $team.OwnerUPN -ErrorAction Stop

                $resultObj = @{
                    TeamName = $team.TeamName
                    Status = "Created Successfully"
                    TeamId = $newTeam.GroupId
                }

                # If ReturnTeamsEmail is true, attempt to fetch via Microsoft.Graph if available
                if ($ReturnTeamsEmail) {
                    if (Get-Module -ListAvailable -Name Microsoft.Graph) {
                        try {
                            # Try to get the General channel email via Graph (best-effort)
                            $mgContext = Get-MgContext -ErrorAction SilentlyContinue
                            if (-not $mgContext) {
                                Connect-MgGraph -Scopes @("ChannelMessage.Send", "Group.Read.All") -ErrorAction Stop
                            }

                            $channels = Get-MgTeamChannel -TeamId $newTeam.GroupId -ErrorAction Stop
                            $general = $channels | Where-Object { $_.DisplayName -eq 'General' }
                            if ($general -and $general.GetMembers) {
                                # Channel email address is not always exposed via Graph; this is a best-effort placeholder
                                $resultObj.GeneralChannelEmail = "(see Graph for channel mailbox)"
                            }
                        }
                        catch {
                            $resultObj.GeneralChannelEmail = "Error fetching via Graph: $($_.Exception.Message)"
                        }
                    }
                    else {
                        $resultObj.GeneralChannelEmail = "Requires Microsoft.Graph module to retrieve channel email"
                    }
                }

                $results += [PSCustomObject]$resultObj

                Write-Host "Successfully created team: $($team.TeamName)" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to create team '$($team.TeamName)': $($_.Exception.Message)"
                $results += [PSCustomObject]@{
                    TeamName = $team.TeamName
                    Status = "Failed: $($_.Exception.Message)"
                }
            }
        }
        
        return $results
    }
    catch {
        Write-Error "Error processing CSV: $_"
        exit 1
    }
}

# Main execution
try {
    # Connect to Microsoft Teams
    Connect-Teams
    
    # Process the CSV and create teams
    $results = New-TeamsGroupFromCsv -CsvPath $CsvPath -ReturnTeamsEmail $ReturnTeamsEmail
    
    # Output results
    $results | Format-Table -AutoSize
}
catch {
    Write-Error "Script execution failed: $_"
    exit 1
}
