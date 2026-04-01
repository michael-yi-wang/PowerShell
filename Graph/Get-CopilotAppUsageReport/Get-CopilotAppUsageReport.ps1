<#
.SYNOPSIS
    Get-CopilotAppUsageReport.ps1 - Generates a Microsoft 365 Copilot Usage Report with enriched user data from Entra ID.

.DESCRIPTION
    This script connects to the Microsoft Graph API to retrieve the Microsoft 365 Copilot Usage User Detail report.
    It then enriches this data by fetching the Department and Office Location for each user from Entra ID.
    The final consolidated report is exported to a CSV file.

.PARAMETER TenantId
    The ID or Name of the Microsoft 365 Tenant.

.PARAMETER Period
    The period of the report. Supported values: D7, D30, D90, D180. Default is D30.

.PARAMETER OutputPath
    The directory path to save the output CSV. Default is the current directory.

.PARAMETER LogPath
    The directory path to save the log file. Default is the current directory.

.EXAMPLE
    .\Get-CopilotAppUsageReport.ps1 -TenantId "contoso.onmicrosoft.com" -Period D90
#>

param (
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [ValidateSet('D7', 'D30', 'D90', 'D180')]
    [string]$Period = 'D30',

    [string]$OutputPath = $PSScriptRoot,

    [string]$LogPath = $PSScriptRoot
)

# --- Configuration & Initialization ---
$Timestamp = Get-Date -Format "yyyyMMdd_HHmmss"
$LogFile = Join-Path $LogPath "CopilotReportLog_$Timestamp.txt"
$ReportFile = Join-Path $OutputPath "CopilotAppUsageReport_$Timestamp.csv"

# Function for detailed logging
function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $Time = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $LogMessage = "[$Time] [$Level] $Message"
    
    # Color coding for console output
    switch ($Level) {
        'Info'    { $Color = 'Green' }
        'Warning' { $Color = 'Yellow' }
        'Error'   { $Color = 'Red' }
    }
    
    Write-Host $LogMessage -ForegroundColor $Color
    $LogMessage | Out-File -FilePath $LogFile -Append -Encoding utf8
}

try {
    Write-Log "Starting Microsoft 365 Copilot Usage Report generation script."
    
    # Check for Microsoft.Graph modules
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Authentication)) {
        throw "Microsoft.Graph.Authentication module is not installed. Please install it using 'Install-Module Microsoft.Graph'."
    }
    if (-not (Get-Module -ListAvailable Microsoft.Graph.Users)) {
        throw "Microsoft.Graph.Users module is not installed. Please install it using 'Install-Module Microsoft.Graph'."
    }

    # --- Connection ---
    Write-Log "Connecting to Microsoft Graph for Tenant: $TenantId"
    # Scopes: Reports.Read.All (for usage), User.Read.All (for attributes)
    Connect-MgGraph -TenantId $TenantId -Scopes "Reports.Read.All", "User.Read.All" -NoWelcome

    # --- Fetching Usage Data ---
    Write-Log "Fetching Copilot Usage User Detail report for period: $Period"
    
    $UsageData = @()
    # Using the beta reports endpoint which is standard for usage reports
    $Uri = "https://graph.microsoft.com/beta/reports/getMicrosoft365CopilotUsageUserDetail(period='$Period')"
    
    do {
        $Response = Invoke-MgGraphRequest -Method Get -Uri $Uri
        
        if ($Response.value) {
            $UsageData += $Response.value
            Write-Log "Retrieved $($Response.value.Count) records (Total so far: $($UsageData.Count))..."
        }
        
        # Follow pagination link if it exists
        $Uri = $Response.'@odata.nextLink'
    } while ($null -ne $Uri)
    
    if ($UsageData.Count -eq 0) {
        Write-Log "No usage data found for the specified period." -Level Warning
        return
    }
    Write-Log "Successfully retrieved all $($UsageData.Count) usage records."

    # --- Fetching Entra ID User Details ---
    # To be efficient, we fetch user properties for all users in the report in batches or a single call if possible
    Write-Log "Enriching data with Department and Office Location from Entra ID..."
    
    $FinalResults = New-Object System.Collections.Generic.List[PSObject]
    $UserCache = @{} # Local cache to avoid redundant Graph calls for the same user

    $Counter = 0
    foreach ($Record in $UsageData) {
        $Counter++
        $UPN = $Record.userPrincipalName
        
        if (-not $UserCache.ContainsKey($UPN)) {
            try {
                $UserInfo = Get-MgUser -UserId $UPN -Property Department, OfficeLocation -ErrorAction Stop
                $UserCache[$UPN] = @{
                    Department     = $UserInfo.Department
                    OfficeLocation = $UserInfo.OfficeLocation
                }
            } catch {
                Write-Log "Could not find extra info for user: $UPN" -Level Warning
                $UserCache[$UPN] = @{
                    Department     = "N/A"
                    OfficeLocation = "N/A"
                }
            }
        }

        # Combine Usage Record with Entra ID Info
        $CombinedObject = [PSCustomObject]@{
            "User Principal Name"                         = $Record.userPrincipalName
            "Display Name"                                = $Record.displayName
            "Department"                                  = $UserCache[$UPN].Department
            "Office Location"                             = $UserCache[$UPN].OfficeLocation
            "Last Activity Date"                          = $Record.lastActivityDate
            "Microsoft Teams Copilot Last Activity Date"  = $Record.microsoftTeamsCopilotLastActivityDate
            "Word Copilot Last Activity Date"             = $Record.wordCopilotLastActivityDate
            "Excel Copilot Last Activity Date"            = $Record.excelCopilotLastActivityDate
            "PowerPoint Copilot Last Activity Date"       = $Record.powerPointCopilotLastActivityDate
            "Outlook Copilot Last Activity Date"          = $Record.outlookCopilotLastActivityDate
            "OneNote Copilot Last Activity Date"          = $Record.oneNoteCopilotLastActivityDate
            "Loop Copilot Last Activity Date"             = $Record.loopCopilotLastActivityDate
            "Copilot Chat Last Activity Date"             = $Record.copilotChatLastActivityDate
            "Report Refresh Date"                         = $Record.reportRefreshDate
            "Report Period"                               = $Record.reportPeriod
        }
        $FinalResults.Add($CombinedObject)
        
        if ($Counter % 50 -eq 0) {
            Write-Log "Processed $Counter records..."
        }
    }

    # --- Export ---
    Write-Log "Exporting results to: $ReportFile"
    $FinalResults | Export-Csv -Path $ReportFile -NoTypeInformation -Encoding utf8
    Write-Log "Report generation complete."

} catch {
    Write-Log "Critical Error: $($_.Exception.Message)" -Level Error
    Write-Log "Stack Trace: $($_.ScriptStackTrace)" -Level Error
} finally {
    Write-Log "Disconnecting from Microsoft Graph."
    Disconnect-MgGraph
}
