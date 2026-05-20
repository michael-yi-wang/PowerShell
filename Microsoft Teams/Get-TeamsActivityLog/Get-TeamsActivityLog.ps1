#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieves the most recent Microsoft Teams activity date for all active users, grouped by Office Location.

.DESCRIPTION
    Connects to Microsoft Graph (app-only or interactive) and retrieves Teams user activity
    from the Microsoft Graph Reports API for all active, non-guest users in the tenant.

    The Reports API returns a pre-aggregated "Last Activity Date" per user — the most recent
    date on which the user participated in any Teams activity (chat, calls, meetings, etc.).
    Device-type usage flags (Desktop, Mobile, Web) are sourced from the Teams Device Usage
    report and indicate whether the user used that platform type at least once in the period.

    Results are grouped by Office Location and written to:
      <script_dir>/report/<OfficeLocation>/YYYY/MM/<OfficeLocation>-TeamsActivity-YYYYMMDD.csv

    Optionally uploads each location CSV to SharePoint Online under:
      {DocumentLibrary}/{BaseFolderPath}/{OfficeLocation}/YYYY/MM/

    Execution logs are written to:
      <script_dir>/logs/Get-TeamsActivityLog_YYYYMMDD_HHmmss.log

.PARAMETER TenantId
    Entra ID Tenant ID (GUID).

.PARAMETER ClientId
    App Registration Client ID. Required for certificate-based (non-interactive) auth.

.PARAMETER CertificateThumbprint
    Certificate thumbprint for non-interactive auth. Must be installed in the current user
    or local machine certificate store. Recommended for Windows.

.PARAMETER CertificatePath
    Full path to a .pfx certificate file. Cross-platform alternative to -CertificateThumbprint.

.PARAMETER CertificatePassword
    SecureString password for the .pfx file. Required when -CertificatePath is used.

.PARAMETER Period
    Reporting period for both the activity and device usage reports.
    Accepted values: D7, D30, D90, D180.
    Default: D30.

.PARAMETER SharePointSiteUrl
    Full SharePoint Online site URL.
    Example: https://contoso.sharepoint.com/sites/IT

.PARAMETER SharePointDocumentLibrary
    Site-relative URL name of the document library (use URL name, not display name).
    Default: "Documents"

.PARAMETER SharePointBaseFolderPath
    Base folder within the document library. Files are organised under
    {BaseFolderPath}/{OfficeLocation}/YYYY/MM/
    Default: "Teams Activity"

.PARAMETER SkipSharePointUpload
    Skip uploading reports to SharePoint Online. Useful for testing or local-only runs.

.EXAMPLE
    # Interactive run — local report only, 30-day period
    .\Get-TeamsActivityLog.ps1 `
        -TenantId         'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -SkipSharePointUpload

.EXAMPLE
    # App-only (certificate thumbprint) with SharePoint upload, 90-day period
    .\Get-TeamsActivityLog.ps1 `
        -TenantId              'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -ClientId              'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -CertificateThumbprint 'ABCDEF1234567890ABCDEF1234567890ABCDEF12' `
        -Period                D90 `
        -SharePointSiteUrl     'https://contoso.sharepoint.com/sites/IT' `
        -SharePointDocumentLibrary 'Documents' `
        -SharePointBaseFolderPath  'Teams Activity'

.EXAMPLE
    # App-only (PFX file, macOS) with SharePoint upload, 7-day period
    $pwd = Read-Host -AsSecureString 'Certificate password'
    .\Get-TeamsActivityLog.ps1 `
        -TenantId            'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -ClientId            'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -CertificatePath     '/Users/admin/certs/app.pfx' `
        -CertificatePassword $pwd `
        -Period              D7 `
        -SharePointSiteUrl   'https://contoso.sharepoint.com/sites/IT'

.NOTES
    Author  : Michael Wang
    Version : 3.0.1
    Date    : 2026-05-19

    Breaking changes from v2.x:
        - Removed -DaysBack, -NonInteractiveDaysBack, -NonInteractiveParallelism parameters
        - Added -Period parameter (D7/D30/D90/D180; default D30)
        - Removed TeamsDesktopLastLogin_UTC and TeamsMobileLastLogin_UTC output columns
        - Renamed TeamsLastLogin_UTC to TeamsLastActivity_Date (date-only, YYYY-MM-DD)
        - Added TeamsUsedDesktop, TeamsUsedMobile, TeamsUsedWeb output columns

    Required Microsoft Graph API Permissions (Application):
        User.Read.All
        Reports.Read.All

    Note: If the tenant has Microsoft 365 usage report anonymization enabled
    (M365 Admin Center > Settings > Org Settings > Reports > Privacy), the Reports API
    returns obfuscated user identifiers and the script will warn that data cannot be joined.

    SharePoint Permissions (when -SkipSharePointUpload is NOT specified):
        SharePoint API (Application): Sites.Selected
        Grant site-level access:
          Grant-PnPAzureADAppSitePermission -AppId <ClientId> -DisplayName <AppName> `
              -Site <SiteUrl> -Permissions Manage

    Required PowerShell Modules:
        Microsoft.Graph.Authentication    (Connect-MgGraph, Disconnect-MgGraph, Invoke-MgGraphRequest)
        Microsoft.Graph.Users             (Get-MgUser)
        PnP.PowerShell                    (required unless -SkipSharePointUpload is specified)
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true, HelpMessage = "Entra ID Tenant ID (GUID)")]
    [ValidateNotNullOrEmpty()]
    [guid]$TenantId,

    [Parameter(Mandatory = $false, HelpMessage = "App Registration Client ID for non-interactive auth")]
    [string]$ClientId,

    [Parameter(Mandatory = $false, HelpMessage = "Certificate thumbprint for non-interactive auth")]
    [string]$CertificateThumbprint,

    [Parameter(Mandatory = $false, HelpMessage = "Path to a .pfx certificate file (cross-platform alternative to thumbprint)")]
    [ValidateScript({
        if (-not [string]::IsNullOrWhiteSpace($_) -and -not (Test-Path $_ -PathType Leaf)) {
            throw "Certificate file not found: $_"
        }
        $true
    })]
    [string]$CertificatePath,

    [Parameter(Mandatory = $false, HelpMessage = "SecureString password for the .pfx file")]
    [SecureString]$CertificatePassword,

    [Parameter(Mandatory = $false, HelpMessage = "Reporting period for Teams activity and device usage reports (D7, D30, D90, D180)")]
    [ValidateSet('D7', 'D30', 'D90', 'D180')]
    [string]$Period = 'D30',

    [Parameter(Mandatory = $false, HelpMessage = "SharePoint Online site URL")]
    [string]$SharePointSiteUrl,

    [Parameter(Mandatory = $false, HelpMessage = "Document library URL name (not display name)")]
    [string]$SharePointDocumentLibrary = "Documents",

    [Parameter(Mandatory = $false, HelpMessage = "Base folder path within the document library")]
    [string]$SharePointBaseFolderPath = "Teams Activity",

    [Parameter(Mandatory = $false, HelpMessage = "Skip uploading reports to SharePoint Online")]
    [switch]$SkipSharePointUpload
)

#region Initialization

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$ScriptRoot      = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
$scriptStartTime = Get-Date
$RunDate         = $scriptStartTime.ToString('yyyyMMdd')
$RunDateTime     = $scriptStartTime.ToString('yyyyMMdd_HHmmss')
$YearFolder      = $scriptStartTime.ToString('yyyy')
$MonthFolder     = $scriptStartTime.ToString('MM')

$LogDirectory  = Join-Path $ScriptRoot 'logs'
$ReportBaseDir = Join-Path $ScriptRoot 'report'

if (-not (Test-Path $LogDirectory)) {
    New-Item -ItemType Directory -Path $LogDirectory -Force | Out-Null
}

$LogFile = Join-Path $LogDirectory "Get-TeamsActivityLog_${RunDateTime}.log"

$GraphModules = @(
    'Microsoft.Graph.Authentication',
    'Microsoft.Graph.Users'
)

#endregion

#region Functions

function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $entry = "[{0}] [{1,-7}] {2}" -f (Get-Date -Format 'yyyy-MM-dd HH:mm:ss'), $Level, $Message

    switch ($Level) {
        'Info'    { Write-Host $entry -ForegroundColor Green }
        'Warning' { Write-Host $entry -ForegroundColor Yellow }
        'Error'   { Write-Host $entry -ForegroundColor Red }
    }

    Add-Content -Path $LogFile -Value $entry -Encoding UTF8
}

function Assert-RequiredModule {
    param ([string]$ModuleName)

    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Log "Required module '$ModuleName' is not installed. Run: Install-Module $ModuleName -Scope CurrentUser" -Level Error
        throw "Module '$ModuleName' is required but not installed."
    }
}

function Get-SafeFolderName {
    param ([string]$Name)

    if ([string]::IsNullOrWhiteSpace($Name)) { return 'Unknown_Location' }

    $safe = ($Name -replace '[\\/:*?"<>|]', '_').Trim().TrimEnd('.')

    # Prefix Windows NTFS reserved device names to prevent filesystem errors on Windows
    if ($safe -match '^(CON|PRN|AUX|NUL|COM[1-9]|LPT[1-9])$') { $safe = "_$safe" }

    return $safe
}

function Get-ActiveUsers {
    Write-Log 'Retrieving active member users from Microsoft Entra ID...'

    try {
        $users = Get-MgUser `
            -Filter           "userType eq 'Member' and accountEnabled eq true" `
            -Select           @('id','displayName','userPrincipalName','mail','officeLocation','jobTitle','department','accountEnabled') `
            -All `
            -ConsistencyLevel eventual `
            -CountVariable    totalCount

        Write-Log "Retrieved $($users.Count) active member user(s)."
        return $users
    }
    catch {
        Write-Log "Failed to retrieve users: $_" -Level Error
        throw
    }
}

function Invoke-TeamsReportDownload {
    # Calls a Graph Reports API URI that returns a 302 redirect to a pre-authenticated
    # CSV download URL, then downloads and returns the CSV text.
    [CmdletBinding()]
    param ([string]$Uri, [string]$Label)

    Write-Log "Fetching $Label report..."

    $httpResponse = Invoke-MgGraphRequest -Uri $Uri -OutputType HttpResponseMessage -ErrorAction Stop
    $downloadUrl  = $null

    try {
        $statusCode = [int]$httpResponse.StatusCode

        if ($statusCode -eq 302 -or $statusCode -eq 301) {
            $downloadUrl = $httpResponse.Headers.Location.AbsoluteUri
        }
        elseif ($statusCode -eq 200) {
            # SDK followed the redirect automatically — read content directly.
            $content = $httpResponse.Content.ReadAsStringAsync().GetAwaiter().GetResult()
            return $content
        }
        else {
            throw "Unexpected HTTP $statusCode from Graph Reports API ($Label)."
        }
    }
    finally {
        $httpResponse.Dispose()
    }

    # Pre-authenticated download URL — no Authorization header needed.
    $csvText = Invoke-RestMethod -Uri $downloadUrl -Method GET -ErrorAction Stop
    return $csvText
}

function Get-TeamsActivityReport {
    [CmdletBinding()]
    param ([string]$Period)

    $uri = "https://graph.microsoft.com/v1.0/reports/getTeamsUserActivityUserDetail(period='$Period')"
    $csvText = Invoke-TeamsReportDownload -Uri $uri -Label "Teams User Activity ($Period)"

    $lookup = [System.Collections.Generic.Dictionary[string, string]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    $rows = $csvText | ConvertFrom-Csv
    $sampleId = ($rows | Where-Object { -not [string]::IsNullOrWhiteSpace($_.'User Id') } | Select-Object -First 1).'User Id'

    # Warn if tenant anonymization is active (User Id won't be a real GUID).
    if (-not [string]::IsNullOrWhiteSpace($sampleId) -and
        $sampleId -notmatch '^[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}$') {
        Write-Log "Teams activity report user IDs appear anonymized. Enable user-level detail in M365 Admin Center > Settings > Org Settings > Reports." -Level Warning
    }

    foreach ($row in $rows) {
        if ($row.'Is Deleted' -eq 'True') { continue }
        $userId    = $row.'User Id'
        $lastDate  = $row.'Last Activity Date'
        if ([string]::IsNullOrWhiteSpace($userId) -or [string]::IsNullOrWhiteSpace($lastDate)) { continue }
        $lookup[$userId] = $lastDate
    }

    Write-Log "Teams activity report: $($lookup.Count) user(s) with activity in the last $Period."
    return $lookup
}

function Get-TeamsDeviceUsageReport {
    [CmdletBinding()]
    param ([string]$Period)

    $uri = "https://graph.microsoft.com/v1.0/reports/getTeamsDeviceUsageUserDetail(period='$Period')"
    $csvText = Invoke-TeamsReportDownload -Uri $uri -Label "Teams Device Usage ($Period)"

    $lookup = [System.Collections.Generic.Dictionary[string, hashtable]]::new(
        [System.StringComparer]::OrdinalIgnoreCase)

    $rows = $csvText | ConvertFrom-Csv

    foreach ($row in $rows) {
        if ($row.'Is Deleted' -eq 'True') { continue }
        $userId = $row.'User Id'
        if ([string]::IsNullOrWhiteSpace($userId)) { continue }

        # Convert row to a plain hashtable so missing columns return $null without
        # triggering Set-StrictMode errors. Column names are normalised (consecutive
        # whitespace collapsed to a single space) to handle API typos such as
        # "Used  Chrome OS" (two spaces) returned by getTeamsDeviceUsageUserDetail.
        $r = @{}
        foreach ($prop in $row.PSObject.Properties) {
            $r[($prop.Name -replace '\s+', ' ')] = $prop.Value
        }

        $lookup[$userId] = @{
            UsedDesktop = ($r['Used Windows'] -eq 'Yes' -or $r['Used Mac'] -eq 'Yes' -or
                           $r['Used Chrome OS'] -eq 'Yes' -or $r['Used Linux'] -eq 'Yes')
            UsedMobile  = ($r['Used iOS'] -eq 'Yes' -or $r['Used Android Phone'] -eq 'Yes' -or
                           $r['Used Windows Phone'] -eq 'Yes')
            UsedWeb     = ($r['Used Web'] -eq 'Yes')
        }
    }

    Write-Log "Teams device usage report: $($lookup.Count) user(s) with device data in the last $Period."
    return $lookup
}

function Export-TeamsReports {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [object[]]$Users,
        [Parameter(Mandatory = $true)] [hashtable]$ActivityData
    )

    Write-Log 'Building report records...'

    $activityDates = $ActivityData.ActivityDates
    $deviceUsage   = $ActivityData.DeviceUsage
    $results       = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($user in $Users) {
        $uid = $user.Id

        $lastDate    = if ($activityDates.ContainsKey($uid)) { $activityDates[$uid] } else { $null }
        $deviceFlags = if ($deviceUsage.ContainsKey($uid))   { $deviceUsage[$uid]   } else { $null }

        $results.Add([PSCustomObject]@{
            DisplayName            = $user.DisplayName
            Email                  = if ($user.Mail) { $user.Mail } else { $user.UserPrincipalName }
            UserPrincipalName      = $user.UserPrincipalName
            OfficeLocation         = $user.OfficeLocation
            Department             = $user.Department
            Title                  = $user.JobTitle
            AccountEnabled         = $user.AccountEnabled
            TeamsLastActivity_Date = $lastDate
            TeamsUsedDesktop       = if ($null -ne $deviceFlags) { $deviceFlags.UsedDesktop } else { $null }
            TeamsUsedMobile        = if ($null -ne $deviceFlags) { $deviceFlags.UsedMobile }  else { $null }
            TeamsUsedWeb           = if ($null -ne $deviceFlags) { $deviceFlags.UsedWeb }     else { $null }
        })
    }

    $groups = $results | Group-Object -Property { Get-SafeFolderName $_.OfficeLocation }

    Write-Log "Exporting $($groups.Count) location group(s) to CSV..."

    $exportedFiles = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($group in $groups) {
        $locationName = $group.Name
        $outputDir    = Join-Path $ReportBaseDir $locationName $YearFolder $MonthFolder

        if (-not (Test-Path $outputDir)) {
            New-Item -ItemType Directory -Path $outputDir -Force | Out-Null
        }

        $fileName   = "${locationName}-TeamsActivity-${RunDate}.csv"
        $outputFile = Join-Path $outputDir $fileName

        $group.Group | Export-Csv -Path $outputFile -NoTypeInformation -Encoding UTF8

        Write-Log "  [$locationName] $($group.Group.Count) record(s) -> $outputFile"

        $exportedFiles.Add([PSCustomObject]@{
            LocationName = $locationName
            FilePath     = $outputFile
            FileName     = $fileName
        })
    }

    Write-Log "Report export complete. Total users: $($results.Count)"
    # Unary comma preserves the List<T> as a single object; without it PowerShell unwraps it.
    return , $exportedFiles
}

function Invoke-SharePointUpload {
    # Implicit script-scope dependencies (read-only):
    #   $SharePointSiteUrl, $SharePointDocumentLibrary, $SharePointBaseFolderPath
    #   $TenantId, $ClientId, $CertificateThumbprint, $CertificatePath, $CertificatePassword
    #   $YearFolder, $MonthFolder
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [System.Collections.Generic.List[PSCustomObject]]$ExportedFiles,

        [Parameter(Mandatory = $true)]
        [bool]$UseAppOnlyAuth,

        [Parameter(Mandatory = $true)]
        [bool]$UseThumbprint
    )

    Write-Log "Connecting to SharePoint Online: $SharePointSiteUrl"

    try {
        if ($UseAppOnlyAuth) {
            $pnpParams = @{
                Url    = $SharePointSiteUrl
                Tenant = $TenantId.ToString()
            }

            if ($UseThumbprint) {
                $pnpParams['ClientId']   = $ClientId
                $pnpParams['Thumbprint'] = $CertificateThumbprint
            }
            else {
                $pnpParams['ClientId']            = $ClientId
                $pnpParams['CertificatePath']     = $CertificatePath
                $pnpParams['CertificatePassword'] = $CertificatePassword
            }

            Connect-PnPOnline @pnpParams
        }
        else {
            Connect-PnPOnline -Url $SharePointSiteUrl -Interactive
        }

        Write-Log "Connected to SharePoint Online."
    }
    catch {
        Write-Log "Failed to connect to SharePoint Online: $_" -Level Error
        throw
    }

    try {
        $library     = Get-PnPList -Identity $SharePointDocumentLibrary -Includes RootFolder -ErrorAction Stop
        $libraryRoot = $library.RootFolder.ServerRelativeUrl.TrimEnd('/')
        Write-Log "Library root: $libraryRoot"

        foreach ($fileInfo in $ExportedFiles) {
            # Folder hierarchy: BaseFolderPath / OfficeLocation / YYYY / MM
            $baseSegments   = $SharePointBaseFolderPath.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
            $folderSegments = @($baseSegments) + @($fileInfo.LocationName, $YearFolder, $MonthFolder)

            # Create each folder segment only if it does not already exist.
            # Get-PnPFolder existence check avoids brittle exception-message matching.
            $currentPath = $libraryRoot
            foreach ($segment in $folderSegments) {
                $folderUrl = "$currentPath/$segment"
                try {
                    Get-PnPFolder -Url $folderUrl -ErrorAction Stop | Out-Null
                }
                catch {
                    Add-PnPFolder -Name $segment -Folder $currentPath -ErrorAction Stop | Out-Null
                }
                $currentPath = $folderUrl
            }
            $targetFolder = $currentPath

            Write-Log "Uploading '$($fileInfo.FileName)' to $targetFolder..."
            Add-PnPFile -Path $fileInfo.FilePath -Folder $targetFolder | Out-Null
            Write-Log "Uploaded: $targetFolder/$($fileInfo.FileName)"
        }
    }
    catch {
        Write-Log "Failed during SharePoint upload: $_" -Level Error
        throw
    }
    finally {
        try { Disconnect-PnPOnline; Write-Log "Disconnected from SharePoint Online." }
        catch { Write-Log "Could not cleanly disconnect from SharePoint Online." -Level Warning }
    }
}

#endregion

#region Main

Write-Log "=== Get-TeamsActivityLog v3.0.1 ==="
Write-Log "Start Time  : $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Log "Period      : $Period"
Write-Log "Report Dir  : $ReportBaseDir"

# Validate SharePoint parameters
if (-not $SkipSharePointUpload -and [string]::IsNullOrWhiteSpace($SharePointSiteUrl)) {
    Write-Log "-SharePointSiteUrl is required unless -SkipSharePointUpload is specified." -Level Error
    exit 1
}

# Determine authentication mode
$clientIdProvided   = -not [string]::IsNullOrWhiteSpace($ClientId)
$thumbprintProvided = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)
$certPathProvided   = -not [string]::IsNullOrWhiteSpace($CertificatePath)

if ($certPathProvided -and $null -eq $CertificatePassword) {
    Write-Log "-CertificatePassword is required when -CertificatePath is used." -Level Error
    exit 1
}

$useAppOnlyAuth = $clientIdProvided -and ($thumbprintProvided -or $certPathProvided)
Write-Log "Auth Mode   : $(if ($useAppOnlyAuth) { 'App-Only (Certificate)' } else { 'Interactive (Delegated)' })"

# Validate required modules
foreach ($module in $GraphModules) { Assert-RequiredModule -ModuleName $module }
if (-not $SkipSharePointUpload) { Assert-RequiredModule -ModuleName 'PnP.PowerShell' }

foreach ($module in $GraphModules) { Import-Module $module -ErrorAction Stop }
if (-not $SkipSharePointUpload) { Import-Module PnP.PowerShell -ErrorAction Stop }

# Connect to Microsoft Graph
try {
    Write-Log "Connecting to Microsoft Graph (TenantId: $TenantId)..."

    $connectParams = @{ TenantId = $TenantId.ToString(); NoWelcome = $true }

    if ($useAppOnlyAuth) {
        $connectParams['ClientId'] = $ClientId

        if ($thumbprintProvided) {
            $connectParams['CertificateThumbprint'] = $CertificateThumbprint
            Write-Log "Authentication method: certificate thumbprint."
            Connect-MgGraph @connectParams
        }
        else {
            Write-Log "Authentication method: certificate file ($CertificatePath)."
            $cert = $null
            try {
                # EphemeralKeySet avoids writing the private key to disk on shared systems.
                # Graph copies the key material at connect time, so the object is safe to dispose immediately after.
                $cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                    $CertificatePath,
                    $CertificatePassword,
                    [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
                )
                $connectParams['Certificate'] = $cert
                Connect-MgGraph @connectParams
            }
            finally {
                if ($null -ne $cert) { $cert.Dispose() }
            }
        }
    }
    else {
        $connectParams['Scopes'] = @('User.Read.All', 'Reports.Read.All')
        Write-Log "Authentication method: interactive (delegated)."
        Connect-MgGraph @connectParams
    }

    Write-Log "Connected to Microsoft Graph successfully."
}
catch {
    Write-Log "Failed to connect to Microsoft Graph: $_" -Level Error
    exit 1
}

# Main data collection and export
$hadError      = $false
$exportedFiles = $null
try {
    $activeUsers = Get-ActiveUsers

    if ($activeUsers.Count -eq 0) {
        Write-Log 'No active users found. Nothing to report.' -Level Warning
        exit 0
    }

    $activityDates = Get-TeamsActivityReport    -Period $Period
    $deviceUsage   = Get-TeamsDeviceUsageReport -Period $Period

    $exportedFiles = Export-TeamsReports -Users $activeUsers -ActivityData @{
        ActivityDates = $activityDates
        DeviceUsage   = $deviceUsage
    }
}
catch {
    Write-Log "An unexpected error occurred: $_" -Level Error
    Write-Log $_.ScriptStackTrace -Level Error
    $hadError = $true
}
finally {
    try { Disconnect-MgGraph | Out-Null; Write-Log "Disconnected from Microsoft Graph." }
    catch { Write-Log "Could not disconnect from Microsoft Graph cleanly." -Level Warning }
}

if ($hadError) { exit 1 }

# SharePoint upload
if (-not $SkipSharePointUpload -and $null -ne $exportedFiles -and $exportedFiles.Count -gt 0) {
    try {
        Invoke-SharePointUpload `
            -ExportedFiles  $exportedFiles `
            -UseAppOnlyAuth $useAppOnlyAuth `
            -UseThumbprint  $thumbprintProvided
    }
    catch {
        Write-Log "SharePoint upload failed: $_" -Level Error
        exit 1
    }
}
elseif ($SkipSharePointUpload) {
    Write-Log "SharePoint upload skipped (-SkipSharePointUpload)."
}

# Summary
$duration = (Get-Date) - $scriptStartTime
Write-Log "=== Script Completed ==="
Write-Log "Duration  : $($duration.ToString('d\.hh\:mm\:ss'))"
Write-Log "Reports   : $ReportBaseDir"
Write-Log "Log File  : $LogFile"

#endregion
