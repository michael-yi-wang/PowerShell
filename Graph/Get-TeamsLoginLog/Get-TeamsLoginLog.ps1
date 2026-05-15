#Requires -Modules Microsoft.Graph.Reports, Microsoft.Graph.Users
<#
.SYNOPSIS
    Retrieves Microsoft Teams login activity for users in a specified office location over the past 30 days.

.DESCRIPTION
    Connects to Microsoft Graph, downloads the Teams user activity report (D30),
    filters by office location, and exports matching active users to a CSV file.

.PARAMETER OfficeLocation
    The office location value to filter users by (e.g., "SCO", "New York").

.PARAMETER OutputPath
    Full file path for the output CSV (e.g., "~/Desktop/TFY-Teams.csv").

.EXAMPLE
    .\Get-TeamsLoginLog.ps1 -OfficeLocation "SCO" -OutputPath "~/Desktop/SCO-Teams.csv"

.NOTES
    Author      : Michael
    Date        : 2026-05-14
    Requirements: Microsoft.Graph PowerShell module
    Permissions : Reports.Read.All, User.Read.All
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [string]$OfficeLocation,

    [Parameter(Mandatory = $true)]
    [string]$OutputPath
)

# --- Logging ---
$logDir  = Join-Path $PSScriptRoot "logs"
if (-not (Test-Path $logDir)) { New-Item -ItemType Directory -Path $logDir | Out-Null }
$logFile = Join-Path $logDir "Get-TeamsLoginLog_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

# --- Validate output path ---
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
if (-not (Test-Path (Split-Path $OutputPath -Parent))) {
    Write-Log "Output directory '$(Split-Path $OutputPath -Parent)' does not exist." -Level Error
    return
}

# --- Connect to Microsoft Graph ---
$connected = $false
if (Get-MgContext) {
    Write-Log "Using existing Microsoft Graph session ($((Get-MgContext).Account))."
} else {
    try {
        Write-Log "Connecting to Microsoft Graph..."
        Connect-MgGraph -NoWelcome -Scopes "Reports.Read.All", "User.Read.All" -ErrorAction Stop
        $connected = $true
        Write-Log "Connected successfully."
    } catch {
        Write-Log "Failed to connect to Microsoft Graph: $_" -Level Error
        return
    }
}

# --- Main ---
$tempReport = Join-Path $PSScriptRoot ".tmp_TeamsActivity_$(Get-Date -Format 'yyyyMMddHHmmss').csv"

try {
    # Download Teams activity report
    # Note: Get-MgReportTeamUserActivityUserDetail -OutFile throws ProgressRecord.PercentComplete
    # ArgumentOutOfRangeException (Int32.MaxValue) when response lacks Content-Length — Graph SDK bug.
    # Invoke-MgGraphRequest uses a different download path that avoids this.
    Write-Log "Downloading Teams user activity report (D30)..."
    Invoke-MgGraphRequest `
        -Uri "https://graph.microsoft.com/v1.0/reports/getTeamsUserActivityUserDetail(period='D30')" `
        -OutputFilePath $tempReport `
        -ErrorAction Stop
    Write-Log "Report downloaded."

    # Get users by office location
    Write-Log "Retrieving users with office location '$OfficeLocation'..."
    $escapedLocation = $OfficeLocation -replace "'", "''"
    $targetUsers = @(Get-MgUser `
        -Filter "officeLocation eq '$escapedLocation'" `
        -All `
        -ConsistencyLevel eventual `
        -CountVariable userCount `
        -Property "Id,DisplayName,UserPrincipalName,OfficeLocation" `
        -ErrorAction Stop |
        Select-Object DisplayName, UserPrincipalName)

    if ($targetUsers.Count -eq 0) {
        Write-Log "No users found with office location '$OfficeLocation'." -Level Warning
        return
    }
    Write-Log "Found $($targetUsers.Count) user(s)."

    # Cross-reference with activity report
    $upnToName = @{}
    $targetUsers | ForEach-Object { $upnToName[$_.UserPrincipalName] = $_.DisplayName }

    $results = @(Import-Csv -Path $tempReport | Where-Object {
        $_."User Principal Name" -in $upnToName.Keys -and
        $_."Last Activity Date" -ne ""
    } | Select-Object `
        @{ Name = 'Display Name';              Expression = { $upnToName[$_."User Principal Name"] } },
        "User Principal Name",
        "Last Activity Date",
        "Is Licensed",
        "Team Chat Message Count",
        "Private Chat Message Count",
        "Call Count",
        "Meeting Count",
        "Meetings Organized Count",
        "Meetings Attended Count")

    Write-Log "Matched $($results.Count) active record(s)."

    # Export
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -Encoding UTF8 -ErrorAction Stop
    Write-Log "Results exported to: $OutputPath"

} catch {
    Write-Log "Error: $_" -Level Error
} finally {
    if (Test-Path $tempReport) {
        Remove-Item $tempReport -Force
        Write-Log "Temporary report file removed."
    }
    if ($connected) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue | Out-Null
        Write-Log "Disconnected from Microsoft Graph."
    }
}

Write-Log "Script completed."
