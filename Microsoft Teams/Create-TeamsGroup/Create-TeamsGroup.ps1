[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$CsvPath,
    
    [Parameter(Mandatory = $false)]
    [bool]$ReturnTeamsEmail = $false
)

function Connect-MgGraphAndTeams {
    try {
        # Check if already connected to Graph
        $context = Get-MgContext
        if (-not $context) {
            # Connect to Microsoft Graph with required scopes
            Connect-MgGraph -Scopes "Group.ReadWrite.All", "User.Read.All"
        }
        
        Write-Host "Successfully connected to Microsoft Graph" -ForegroundColor Green
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph: $_"
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
                # Create Microsoft 365 Group with Teams functionality
                $newGroup = New-MgGroup -DisplayName $team.TeamName `
                    -MailNickname ($team.TeamName -replace '[^a-zA-Z0-9]', '') `
                    -MailEnabled $true `
                    -SecurityEnabled $true `
                    -GroupTypes @("Unified") `
                    -Visibility "Private"
                
                # Enable Teams functionality
                New-MgTeam -TeamId $newGroup.Id
                
                # Get owner user ID
                $owner = Get-MgUser -Filter "userPrincipalName eq '$($team.OwnerUPN)'"
                if (-not $owner) {
                    throw "Owner not found: $($team.OwnerUPN)"
                }
                
                # Add owner to the team
                New-MgGroupOwner -GroupId $newGroup.Id -DirectoryObjectId $owner.Id
                
                $resultObj = @{
                    TeamName = $team.TeamName
                    Status = "Created Successfully"
                    TeamId = $newGroup.Id
                }
                
                # If ReturnTeamsEmail is true, get the email address
                if ($ReturnTeamsEmail) {
                    $resultObj.GeneralChannelEmail = "$($newGroup.MailNickname)@$((Get-MgDomain | Where-Object IsDefault -eq $true).Id)"
                }
                
                $results += [PSCustomObject]$resultObj
                
                Write-Host "Successfully created team: $($team.TeamName)" -ForegroundColor Green
            }
            catch {
                Write-Warning "Failed to create team '$($team.TeamName)': $_"
                $results += [PSCustomObject]@{
                    TeamName = $team.TeamName
                    Status = "Failed: $_"
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
    # Connect to Microsoft Graph
    Connect-MgGraphAndTeams
    
    # Process the CSV and create teams
    $results = New-TeamsGroupFromCsv -CsvPath $CsvPath -ReturnTeamsEmail $ReturnTeamsEmail
    
    # Output results
    $results | Format-Table -AutoSize
}
catch {
    Write-Error "Script execution failed: $_"
    exit 1
}
