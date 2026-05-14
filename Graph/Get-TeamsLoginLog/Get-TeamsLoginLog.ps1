#Requires -Modules Microsoft.Graph
<#
.SYNOPSIS
    Retrieves Microsoft Teams login activity for users in a specified office location over the past 30 days.

.DESCRIPTION
    Connects to Microsoft Graph, downloads the Teams user activity report (D30),
    filters users by the specified office location, cross-references both data sets,
    and exports matching results to a CSV file on the Desktop.

.PARAMETER OfficeLocation
    The office location value to filter users by (e.g., "SCO", "New York").

.PARAMETER OutputPath
    Optional. Directory to save the output CSV. Defaults to the current user's Desktop.

.EXAMPLE
    .\Get-TeamsLoginLog.ps1 -OfficeLocation "SCO"

.EXAMPLE
    .\Get-TeamsLoginLog.ps1 -OfficeLocation "New York" -OutputPath "C:\Reports"

.NOTES
    Author      : Michael
    Date        : 2026-05-14
    Requirements: Microsoft.Graph PowerShell module
    Permissions : Reports.Read.All, User.Read.All
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Enter the office location to filter users (e.g. 'SCO')")]
    [string]$OfficeLocation,

    [Parameter(Mandatory = $false)]
    [string]$OutputPath = [System.Environment]::GetFolderPath('Desktop')
)

#region --- Logging Helper ---

$logFile = Join-Path $PSScriptRoot "Get-TeamsLoginLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry = "[$timestamp] [$Level] $Message"

    Add-Content -Path $logFile -Value $entry

    switch ($Level) {
        'Info'    { Write-Host $entry -ForegroundColor Green }
        'Warning' { Write-Host $entry -ForegroundColor Yellow }
        'Error'   { Write-Host $entry -ForegroundColor Red }
    }
}

#endregion

#region --- Validate Output Path ---

if (-not (Test-Path $OutputPath)) {
    Write-Log "Output path '$OutputPath' does not exist." -Level Error
    return
}

#endregion

#region --- Connect to Microsoft Graph ---

try {
    Write-Log "Connecting to Microsoft Graph..."
    Connect-MgGraph -Scopes "Reports.Read.All", "User.Read.All" -NoWelcome -ErrorAction Stop
    Write-Log "Connected successfully."
}
catch {
    Write-Log "Failed to connect to Microsoft Graph: $_" -Level Error
    throw
}

#endregion

$tempReport = $null

try {

    #region --- Download Teams Activity Report ---

    $tempReport = Join-Path $env:TEMP "TeamsActivity30Days_$(Get-Date -Format 'yyyyMMddHHmmss').csv"

    try {
        Write-Log "Downloading Teams user activity report for the past 30 days..."

        # Suppress progress bar to avoid known SDK overflow bug
        $ProgressPreference = 'SilentlyContinue'
        Get-MgReportTeamUserActivityUserDetail -Period "D30" -OutFile $tempReport -ErrorAction Stop
    }
    catch {
        Write-Log "Failed to download Teams activity report: $_" -Level Error
        throw
    }
    finally {
        $ProgressPreference = 'Continue'
    }

    Write-Log "Report downloaded to: $tempReport"

    #endregion

    #region --- Get Users by Office Location ---

    try {
        Write-Log "Retrieving users with office location: '$OfficeLocation'..."

        $targetUsers = Get-MgUser `
            -Filter "officeLocation eq '$OfficeLocation'" `
            -All `
            -ConsistencyLevel eventual `
            -CountVariable userCount `
            -Property "Id,DisplayName,UserPrincipalName,OfficeLocation" `
            -ErrorAction Stop |
            Select-Object DisplayName, UserPrincipalName, OfficeLocation

        if ($userCount -eq 0) {
            Write-Log "No users found with office location '$OfficeLocation'. Exiting." -Level Warning
            return
        }

        Write-Log "Found $userCount user(s) with office location '$OfficeLocation'."
    }
    catch {
        Write-Log "Failed to retrieve users: $_" -Level Error
        throw
    }

    #endregion

    #region --- Cross-Reference and Filter ---

    try {
        Write-Log "Cross-referencing users with Teams activity data..."

        $teamsActivity = Import-Csv -Path $tempReport
        $targetUPNs    = $targetUsers.UserPrincipalName
        $upnToName     = @{}
        $targetUsers | ForEach-Object { $upnToName[$_.UserPrincipalName] = $_.DisplayName }

        $results = $teamsActivity | Where-Object {
            $_."User Principal Name" -in $targetUPNs
        } | Select-Object `
            @{ Name = 'Display Name'; Expression = { $upnToName[$_."User Principal Name"] } },
            "User Principal Name",
            "Last Activity Date",
            "Is Licensed",
            "Team Chat Message Count",
            "Private Chat Message Count",
            "Call Count",
            "Meeting Count",
            "Meetings Organized Count",
            "Meetings Attended Count"

        Write-Log "Matched $($results.Count) record(s) with Teams activity in the past 30 days."
    }
    catch {
        Write-Log "Failed to process report data: $_" -Level Error
        throw
    }

    #endregion

    #region --- Export Results ---

    try {
        $outputFile = Join-Path $OutputPath "TeamsLoginLog_${OfficeLocation}_$(Get-Date -Format 'yyyyMMdd').csv"
        $results | Export-Csv -Path $outputFile -NoTypeInformation -ErrorAction Stop
        Write-Log "Results exported to: $outputFile"
    }
    catch {
        Write-Log "Failed to export results: $_" -Level Error
        throw
    }

    #endregion

}
finally {
    if ($tempReport -and (Test-Path $tempReport)) {
        Remove-Item $tempReport -Force
        Write-Log "Temporary report file removed."
    }

    Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
    Write-Log "Disconnected from Microsoft Graph."
}

Write-Log "Script completed successfully."
