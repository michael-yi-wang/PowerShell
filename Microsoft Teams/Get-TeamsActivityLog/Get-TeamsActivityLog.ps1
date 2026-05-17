#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieves Microsoft Teams last sign-in activity for all active users, grouped by Office Location.

.DESCRIPTION
    Connects to Microsoft Graph (app-only or interactive) and retrieves Teams sign-in activity
    from Entra ID audit logs for all active, non-guest users in the tenant.

    Both interactive (credential prompt) and non-interactive (saved credentials / silent token
    refresh) sign-ins are included so that users who launch Teams with saved credentials are
    correctly reflected in the report.

    Desktop vs Mobile classification is based on the sign-in device operating system:
      - Mobile  : iOS, Android, Windows Phone
      - Desktop : Windows, macOS, Linux, ChromeOS, and any sign-in with no OS reported
                  (browser/web client sessions report no OS and are treated as Desktop)

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

.PARAMETER DaysBack
    Number of days to look back in sign-in logs. Default: 30. Maximum: 30 for non-P2 tenants.

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
    # Interactive run — local report only
    .\Get-TeamsActivityLog.ps1 `
        -TenantId         'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -SkipSharePointUpload

.EXAMPLE
    # App-only (certificate thumbprint) with SharePoint upload
    .\Get-TeamsActivityLog.ps1 `
        -TenantId              'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -ClientId              'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -CertificateThumbprint 'ABCDEF1234567890ABCDEF1234567890ABCDEF12' `
        -SharePointSiteUrl     'https://contoso.sharepoint.com/sites/IT' `
        -SharePointDocumentLibrary 'Documents' `
        -SharePointBaseFolderPath  'Teams Activity'

.EXAMPLE
    # App-only (PFX file, macOS) with SharePoint upload, 14-day lookback
    $pwd = Read-Host -AsSecureString 'Certificate password'
    .\Get-TeamsActivityLog.ps1 `
        -TenantId            'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -ClientId            'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
        -CertificatePath     '/Users/admin/certs/app.pfx' `
        -CertificatePassword $pwd `
        -SharePointSiteUrl   'https://contoso.sharepoint.com/sites/IT' `
        -DaysBack            14

.NOTES
    Author  : Michael Wang
    Version : 2.4.0
    Date    : 2026-05-16

    Required Microsoft Graph API Permissions (Application):
        User.Read.All
        AuditLog.Read.All                (covers both interactive and non-interactive sign-in logs)

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

    [Parameter(Mandatory = $false, HelpMessage = "Number of days to look back in sign-in logs (1-30)")]
    [ValidateRange(1, 30)]
    [int]$DaysBack = 30,

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

$MobileOSList = @('iOS', 'Android', 'Windows Phone')

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

function Get-TeamsSignInData {
    [CmdletBinding()]
    param ([int]$DaysBack)

    Write-Log "Querying Teams sign-in logs (interactive + non-interactive) for the last $DaysBack day(s). This may take a while..."

    # $startDate derives from Get-Date only — no user input reaches this filter.
    $startDate   = (Get-Date).ToUniversalTime().AddDays(-$DaysBack).ToString("yyyy-MM-ddTHH:mm:ssZ")
    # Use the stable well-known App ID for Microsoft Teams rather than appDisplayName,
    # which can silently return 0 results if the display name differs in the tenant.
    $baseFilter   = "appId eq '1fec8e78-bce4-4aaf-ab1b-5451cc387264' and status/errorCode eq 0 and createdDateTime ge $startDate"
    $selectFields = 'userId,createdDateTime,deviceDetail'

    # Four separate dictionaries — one per platform per auth type — so the report
    # shows interactive and non-interactive last logins as distinct columns.
    $desktopInteractive    = [System.Collections.Generic.Dictionary[string, DateTimeOffset]]::new()
    $desktopNonInteractive = [System.Collections.Generic.Dictionary[string, DateTimeOffset]]::new()
    $mobileInteractive     = [System.Collections.Generic.Dictionary[string, DateTimeOffset]]::new()
    $mobileNonInteractive  = [System.Collections.Generic.Dictionary[string, DateTimeOffset]]::new()

    $totalRecords = 0
    $stopwatch    = [System.Diagnostics.Stopwatch]::StartNew()

    # Both sign-in types use the /signIns endpoint (beta required for signInEventTypes filter).
    # Non-interactive sign-ins are filtered via signInEventTypes/any(t: t eq 'nonInteractiveUser').
    # Ref: https://learn.microsoft.com/entra/identity/monitoring-health/howto-analyze-activity-logs-with-microsoft-graph
    $signInSources = @(
        @{ Label = 'Interactive';     BaseUri = 'https://graph.microsoft.com/v1.0/auditLogs/signIns'; ODataFilter = $baseFilter;                                                                              DesktopDict = $desktopInteractive;    MobileDict = $mobileInteractive }
        @{ Label = 'Non-Interactive'; BaseUri = 'https://graph.microsoft.com/beta/auditLogs/signIns'; ODataFilter = "$baseFilter and signInEventTypes/any(t: t eq 'nonInteractiveUser')"; DesktopDict = $desktopNonInteractive; MobileDict = $mobileNonInteractive }
    )

    try {
        foreach ($source in $signInSources) {
            Write-Log "Querying $($source.Label) sign-in logs..."
            $sourceCount = 0

            $encodedFilter = [uri]::EscapeDataString($source.ODataFilter)
            $uri = "$($source.BaseUri)?`$filter=$encodedFilter&`$select=$selectFields&`$top=999"

            try {
                do {
                    $response = Invoke-MgGraphRequest -Uri $uri -Method GET -OutputType PSObject -ErrorAction Stop

                    foreach ($record in $response.value) {
                        $sourceCount++
                        $totalRecords++

                        if ($totalRecords % 500 -eq 0) {
                            $elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds, 0)
                            Write-Progress -Activity 'Processing Teams sign-in logs' `
                                -Status "Records processed: $totalRecords (${elapsed}s elapsed)" -PercentComplete -1
                            Write-Log "Processed $totalRecords sign-in records so far..."
                        }

                        $userId = $record.userId
                        if ([string]::IsNullOrWhiteSpace($userId)) { continue }

                        $os = $record.deviceDetail?.operatingSystem
                        # REST response returns createdDateTime as an ISO 8601 string; DateTimeOffset.Parse
                        # handles the Z suffix correctly and produces a UTC offset.
                        $loginTime = [System.DateTimeOffset]::Parse($record.createdDateTime.ToString())
                        # Browser/web client sign-ins report no OS; treat as Desktop (web from a desktop).
                        if ([string]::IsNullOrWhiteSpace($os)) { $os = 'Web' }

                        if ($os -in $MobileOSList) {
                            if (-not $source.MobileDict.ContainsKey($userId) -or $loginTime -gt $source.MobileDict[$userId]) {
                                $source.MobileDict[$userId] = $loginTime
                            }
                        }
                        else {
                            if (-not $source.DesktopDict.ContainsKey($userId) -or $loginTime -gt $source.DesktopDict[$userId]) {
                                $source.DesktopDict[$userId] = $loginTime
                            }
                        }
                    }

                    # PSObject.Properties lookup avoids strict-mode error when @odata.nextLink is absent on the last page.
                    $uri = $response.PSObject.Properties['@odata.nextLink']?.Value
                } while ($uri)
            }
            catch {
                Write-Log "Error while retrieving $($source.Label) sign-in logs: $_" -Level Error
                throw
            }

            Write-Log "$($source.Label) sign-in log query complete. Records: $sourceCount."
        }
    }
    finally {
        Write-Progress -Activity 'Processing Teams sign-in logs' -Completed
        $stopwatch.Stop()
    }

    Write-Log "Total sign-in records processed: $totalRecords."
    Write-Log "Users with Teams Desktop Interactive activity     : $($desktopInteractive.Count)"
    Write-Log "Users with Teams Desktop Non-Interactive activity : $($desktopNonInteractive.Count)"
    Write-Log "Users with Teams Mobile Interactive activity      : $($mobileInteractive.Count)"
    Write-Log "Users with Teams Mobile Non-Interactive activity  : $($mobileNonInteractive.Count)"

    return @{
        DesktopInteractive    = $desktopInteractive
        DesktopNonInteractive = $desktopNonInteractive
        MobileInteractive     = $mobileInteractive
        MobileNonInteractive  = $mobileNonInteractive
    }
}

function Export-TeamsReports {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)] [object[]]$Users,
        [Parameter(Mandatory = $true)] [hashtable]$SignInData
    )

    Write-Log 'Building report records...'

    $results = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($user in $Users) {
        $uid = $user.Id

        $desktopI    = if ($SignInData.DesktopInteractive.ContainsKey($uid))    { $SignInData.DesktopInteractive[$uid].UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') }    else { $null }
        $desktopNI   = if ($SignInData.DesktopNonInteractive.ContainsKey($uid)) { $SignInData.DesktopNonInteractive[$uid].UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
        $mobileI     = if ($SignInData.MobileInteractive.ContainsKey($uid))     { $SignInData.MobileInteractive[$uid].UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') }     else { $null }
        $mobileNI    = if ($SignInData.MobileNonInteractive.ContainsKey($uid))  { $SignInData.MobileNonInteractive[$uid].UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') }  else { $null }

        $results.Add([PSCustomObject]@{
            DisplayName                              = $user.DisplayName
            Email                                    = if ($user.Mail) { $user.Mail } else { $user.UserPrincipalName }
            UserPrincipalName                        = $user.UserPrincipalName
            OfficeLocation                           = $user.OfficeLocation
            Department                               = $user.Department
            Title                                    = $user.JobTitle
            AccountEnabled                           = $user.AccountEnabled
            TeamsDesktopInteractiveLastLogin_UTC     = $desktopI
            TeamsDesktopNonInteractiveLastLogin_UTC  = $desktopNI
            TeamsMobileInteractiveLastLogin_UTC      = $mobileI
            TeamsMobileNonInteractiveLastLogin_UTC   = $mobileNI
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

Write-Log "=== Get-TeamsActivityLog v2.4.0 ==="
Write-Log "Start Time : $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Log "Days Back  : $DaysBack"
Write-Log "Report Dir : $ReportBaseDir"

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
Write-Log "Auth Mode  : $(if ($useAppOnlyAuth) { 'App-Only (Certificate)' } else { 'Interactive (Delegated)' })"

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
        $connectParams['Scopes'] = @('User.Read.All', 'AuditLog.Read.All')
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

    $signInData    = Get-TeamsSignInData -DaysBack $DaysBack
    $exportedFiles = Export-TeamsReports -Users $activeUsers -SignInData $signInData
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
