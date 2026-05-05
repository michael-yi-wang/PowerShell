#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieves Microsoft Teams last sign-in activity (Desktop and Mobile) for all active users.

.DESCRIPTION
    Connects to Microsoft Graph using app-only certificate authentication and retrieves
    Teams sign-in activity from the Entra ID audit logs for all active, non-guest users.

    Desktop vs Mobile is determined by the sign-in's device operating system:
      - Mobile : iOS, Android, Windows Phone
      - Desktop : all other non-empty OS values (Windows, macOS, Linux, etc.)

    Results are grouped by Office Location and written to:
      <script_dir>/report/<office_location>/<YYYY-MM-DD>_teams_activity.csv

    Execution logs are written to:
      <script_dir>/logs/<YYYY-MM-DD_HH-mm-ss>_TeamsActivityLog.log

.PARAMETER TenantId
    Azure AD / Entra ID Tenant ID (GUID).

.PARAMETER ClientId
    Application (Client) ID of the registered Entra application.

.PARAMETER CertificateThumbprint
    Thumbprint of the authentication certificate installed in the local certificate store.
    Recommended for Windows. Works on macOS when the certificate is in the login keychain.

.PARAMETER CertificatePath
    Full path to a .pfx certificate file. Cross-platform alternative to CertificateThumbprint.

.PARAMETER CertificatePassword
    SecureString password for the .pfx file. Required when CertificatePath is used.

.PARAMETER DaysBack
    Number of days to look back in sign-in logs. Default: 30. Maximum: 30 for non-P2 tenants.

.EXAMPLE
    .\Get-TeamsActivityLog.ps1 `
        -TenantId  'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -ClientId  'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -CertificateThumbprint 'ABCDEF1234567890ABCDEF1234567890ABCDEF12'

.EXAMPLE
    $pwd = Read-Host -AsSecureString 'Certificate password'
    .\Get-TeamsActivityLog.ps1 `
        -TenantId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -ClientId       'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -CertificatePath '/Users/admin/certs/app.pfx' `
        -CertificatePassword $pwd `
        -DaysBack 14

.NOTES
    Author  : Michael Wang
    Version : 1.0.0
    Date    : 2026-05-04

    Required Microsoft Graph API Permissions (Application):
        User.Read.All
        AuditLog.Read.All

    Required PowerShell Modules:
        Microsoft.Graph.Authentication
        Microsoft.Graph.Users
        Microsoft.Graph.Identity.SignIns
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$ClientId,

    [Parameter(Mandatory = $false)]
    [string]$CertificateThumbprint,

    [Parameter(Mandatory = $false)]
    [ValidateScript({
        if (-not (Test-Path $_ -PathType Leaf)) {
            throw "Certificate file not found: $_"
        }
        $true
    })]
    [string]$CertificatePath,

    [Parameter(Mandatory = $false)]
    [SecureString]$CertificatePassword,

    [Parameter(Mandatory = $false)]
    [ValidateRange(1, 30)]
    [int]$DaysBack = 30
)

#region Initialization

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot    = $PSScriptRoot
$RunDate       = Get-Date -Format 'yyyy-MM-dd'
$RunDateTime   = Get-Date -Format 'yyyy-MM-dd_HH-mm-ss'
$LogDirectory  = Join-Path $ScriptRoot 'logs'
$ReportBaseDir = Join-Path $ScriptRoot 'report'
$LogFile       = Join-Path $LogDirectory "${RunDateTime}_TeamsActivityLog.log"

$MobileOSList  = @('iOS', 'Android', 'Windows Phone')

$RequiredModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users',
    'Microsoft.Graph.Identity.SignIns'
)

#endregion

#region Functions

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped message to the console and to the log file.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $logEntry  = "[$timestamp] [$Level] $Message"

    $color = switch ($Level) {
        'Info'    { 'Green' }
        'Warning' { 'Yellow' }
        'Error'   { 'Red' }
    }

    Write-Host $logEntry -ForegroundColor $color
    Add-Content -Path $LogFile -Value $logEntry -Encoding UTF8
}

function Test-RequiredModules {
    <#
    .SYNOPSIS
        Checks that all required Graph PowerShell sub-modules are installed.
        Returns $true if all are present, $false otherwise and prints instructions.
    #>
    $missing = @()

    foreach ($module in $RequiredModules) {
        if (-not (Get-Module -ListAvailable -Name $module)) {
            $missing += $module
        }
    }

    if ($missing.Count -gt 0) {
        Write-Host ''
        Write-Host 'ERROR: The following required PowerShell module(s) are not installed:' -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "  - $_" -ForegroundColor Red }
        Write-Host ''
        Write-Host 'To install all required modules, run:' -ForegroundColor Yellow
        Write-Host '  Install-Module -Name Microsoft.Graph -Scope CurrentUser -Repository PSGallery' -ForegroundColor Yellow
        Write-Host ''
        return $false
    }

    return $true
}

function Get-SafeFolderName {
    <#
    .SYNOPSIS
        Sanitizes a string for use as a folder name on both Windows and macOS.
    #>
    param (
        [string]$Name
    )

    if ([string]::IsNullOrWhiteSpace($Name)) {
        return 'Unknown_Location'
    }

    # Remove characters forbidden in Windows/macOS folder names
    $safe = $Name -replace '[\\/:*?"<>|]', '_'
    return $safe.Trim()
}

function Get-ActiveUsers {
    <#
    .SYNOPSIS
        Returns all enabled, non-guest user accounts from Entra ID with the
        properties needed for the report.
    #>
    Write-Log 'Retrieving active member users from Microsoft Entra ID...'

    $selectProps = @(
        'id', 'displayName', 'userPrincipalName',
        'officeLocation', 'jobTitle', 'userType', 'accountEnabled'
    )

    $filter = "userType eq 'Member' and accountEnabled eq true"

    try {
        $users = Get-MgUser `
            -Filter            $filter `
            -Select            $selectProps `
            -All `
            -ConsistencyLevel  eventual `
            -CountVariable     totalCount

        Write-Log "Retrieved $($users.Count) active member user(s)."
        return $users
    }
    catch {
        Write-Log "Failed to retrieve users: $_" -Level Error
        throw
    }
}

function Get-TeamsSignInData {
    <#
    .SYNOPSIS
        Queries Entra ID sign-in logs for Microsoft Teams over the specified
        lookback period and returns the latest Desktop and Mobile login time
        per user (keyed by user object ID).
    #>
    [CmdletBinding()]
    param (
        [int]$DaysBack
    )

    Write-Log "Querying Teams sign-in logs for the last $DaysBack day(s). This may take a while..."

    $startDate    = (Get-Date).ToUniversalTime().AddDays(-$DaysBack).ToString("yyyy-MM-ddTHH:mm:ssZ")
    $odataFilter  = "appDisplayName eq 'Microsoft Teams' and status/errorCode eq 0 and createdDateTime ge $startDate"

    $selectProps = @('userId', 'userPrincipalName', 'createdDateTime', 'deviceDetail')

    $userDesktopLogin = [System.Collections.Generic.Dictionary[string, DateTimeOffset]]::new()
    $userMobileLogin  = [System.Collections.Generic.Dictionary[string, DateTimeOffset]]::new()

    $recordCount  = 0
    $stopwatch    = [System.Diagnostics.Stopwatch]::StartNew()

    try {
        Get-MgAuditLogSignIn `
            -Filter   $odataFilter `
            -Select   $selectProps `
            -All `
            -PageSize 999 |
        ForEach-Object {
            $signIn  = $_
            $recordCount++

            # Progress update every 2 000 records
            if ($recordCount % 2000 -eq 0) {
                $elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds, 0)
                Write-Progress `
                    -Activity        'Processing Teams sign-in logs' `
                    -Status          "Records processed: $recordCount (${elapsed}s elapsed)" `
                    -PercentComplete -1
                Write-Log "Processed $recordCount sign-in records so far..."
            }

            $userId = $signIn.UserId
            if ([string]::IsNullOrWhiteSpace($userId)) { return }

            $os          = $signIn.DeviceDetail.OperatingSystem
            $loginTime   = $signIn.CreatedDateTime

            if ([string]::IsNullOrWhiteSpace($os)) { return }

            if ($os -in $MobileOSList) {
                # Mobile sign-in
                if (-not $userMobileLogin.ContainsKey($userId) -or $loginTime -gt $userMobileLogin[$userId]) {
                    $userMobileLogin[$userId] = $loginTime
                }
            }
            else {
                # Desktop / web sign-in (Windows, macOS, Linux, ChromeOS, etc.)
                if (-not $userDesktopLogin.ContainsKey($userId) -or $loginTime -gt $userDesktopLogin[$userId]) {
                    $userDesktopLogin[$userId] = $loginTime
                }
            }
        }
    }
    catch {
        Write-Log "Error while retrieving sign-in logs: $_" -Level Error
        throw
    }
    finally {
        Write-Progress -Activity 'Processing Teams sign-in logs' -Completed
        $stopwatch.Stop()
    }

    Write-Log "Sign-in log processing complete. Total records processed: $recordCount."
    Write-Log "Users with Teams Desktop activity : $($userDesktopLogin.Count)"
    Write-Log "Users with Teams Mobile activity  : $($userMobileLogin.Count)"

    return @{
        Desktop = $userDesktopLogin
        Mobile  = $userMobileLogin
    }
}

function Export-TeamReports {
    <#
    .SYNOPSIS
        Merges user data with sign-in data, groups results by Office Location,
        and exports each group to a dated CSV file.
    #>
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Users,

        [Parameter(Mandatory = $true)]
        [hashtable]$SignInData
    )

    Write-Log 'Building report records...'

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($user in $Users) {
        $desktopLogin = $null
        $mobileLogin  = $null

        if ($SignInData.Desktop.ContainsKey($user.Id)) {
            $desktopLogin = $SignInData.Desktop[$user.Id].LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
        }
        if ($SignInData.Mobile.ContainsKey($user.Id)) {
            $mobileLogin = $SignInData.Mobile[$user.Id].LocalDateTime.ToString('yyyy-MM-dd HH:mm:ss')
        }

        # Normalise empty office location for grouping
        $officeLocation = if ([string]::IsNullOrWhiteSpace($user.OfficeLocation)) {
            $null
        }
        else {
            $user.OfficeLocation
        }

        $results.Add([PSCustomObject]@{
            DisplayName                   = $user.DisplayName
            UserPrincipalName             = $user.UserPrincipalName
            OfficeLocation                = $officeLocation
            Title                         = $user.JobTitle
            LastLoginDateTime_TeamsDesktop = $desktopLogin
            LastLoginDateTime_TeamsMobile  = $mobileLogin
        })
    }

    # Group by office location; null/empty → 'Unknown_Location'
    $groups = $results | Group-Object -Property { Get-SafeFolderName $_.OfficeLocation }

    Write-Log "Exporting $($groups.Count) location group(s) to CSV..."

    foreach ($group in $groups) {
        $locationFolder = $group.Name    # already sanitised by the group key expression
        $outputDir      = Join-Path $ReportBaseDir $locationFolder

        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }

        $outputFile = Join-Path $outputDir "${RunDate}_teams_activity.csv"
        $group.Group | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

        Write-Log "  [$locationFolder] $($group.Group.Count) record(s) → $outputFile"
    }

    Write-Log "Report export complete. Total users in report: $($results.Count)"
}

#endregion

#region Main

# Ensure log directory exists before first Write-Log call
if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

Write-Log '=========================================='
Write-Log ' Get-TeamsActivityLog  v1.0.0'
Write-Log "  Run date : $RunDate"
Write-Log "  Days back: $DaysBack"
Write-Log '=========================================='

# Validate that exactly one certificate method is supplied
if ([string]::IsNullOrWhiteSpace($CertificateThumbprint) -and [string]::IsNullOrWhiteSpace($CertificatePath)) {
    Write-Log 'You must supply either -CertificateThumbprint or -CertificatePath.' -Level Error
    exit 1
}

if (-not [string]::IsNullOrWhiteSpace($CertificatePath) -and $null -eq $CertificatePassword) {
    Write-Log '-CertificatePassword is required when -CertificatePath is used.' -Level Error
    exit 1
}

# Module check
if (-not (Test-RequiredModules)) {
    exit 1
}

# Import modules
try {
    foreach ($module in $RequiredModules) {
        Import-Module $module -ErrorAction Stop
    }
    Write-Log 'Required modules imported successfully.'
}
catch {
    Write-Log "Failed to import module: $_" -Level Error
    exit 1
}

# Connect to Microsoft Graph
try {
    Write-Log "Connecting to Microsoft Graph (TenantId: $TenantId | ClientId: $ClientId)..."

    $connectParams = @{
        TenantId  = $TenantId
        ClientId  = $ClientId
        NoWelcome = $true
    }

    if (-not [string]::IsNullOrWhiteSpace($CertificateThumbprint)) {
        $connectParams['CertificateThumbprint'] = $CertificateThumbprint
        Write-Log 'Authentication method: certificate thumbprint.'
    }
    else {
        Write-Log "Authentication method: certificate file ($CertificatePath)."

        # EphemeralKeySet avoids writing the private key to disk — important on shared systems
        $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
            $CertificatePath,
            $CertificatePassword,
            [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
        )
        $connectParams['Certificate'] = $cert
    }

    Connect-MgGraph @connectParams
    Write-Log 'Connected to Microsoft Graph successfully.'
}
catch {
    Write-Log "Failed to connect to Microsoft Graph: $_" -Level Error
    exit 1
}

# Main execution block
try {
    $activeUsers = Get-ActiveUsers

    if ($activeUsers.Count -eq 0) {
        Write-Log 'No active users found. Nothing to report.' -Level Warning
        exit 0
    }

    $signInData = Get-TeamsSignInData -DaysBack $DaysBack

    Export-TeamReports -Users $activeUsers -SignInData $signInData

    Write-Log '=========================================='
    Write-Log ' Script completed successfully.'
    Write-Log '=========================================='
}
catch {
    Write-Log "An unexpected error occurred: $_" -Level Error
    Write-Log $_.ScriptStackTrace -Level Error
    exit 1
}
finally {
    # Always disconnect, even on error
    try {
        Disconnect-MgGraph | Out-Null
        Write-Log 'Disconnected from Microsoft Graph.'
    }
    catch {
        Write-Log 'Could not disconnect from Microsoft Graph cleanly.' -Level Warning
    }
}

#endregion
