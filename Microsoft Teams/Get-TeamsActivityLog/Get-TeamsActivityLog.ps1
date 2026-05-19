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

.PARAMETER NonInteractiveDaysBack
    Lookback window specifically for non-interactive sign-in logs.
    Accepted values: D1, D7, D14, D30.
    Non-interactive events (background token refreshes) can be 10–50× more numerous than
    interactive ones; a shorter window significantly reduces run time on large tenants.
    Default: D30 (matches -DaysBack).

.PARAMETER NonInteractiveParallelism
    Number of parallel time-window chunks for the non-interactive sign-in query (1–10).
    The NI window is divided into this many equal slices, each queried by a dedicated
    thread job. Higher values reduce elapsed time but increase Graph API throttle pressure
    (the built-in retry logic handles throttling automatically).
    Default: 5  (i.e. 5 NI chunks + 1 interactive job = 6 parallel jobs total).

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
    Version : 2.7.0
    Date    : 2026-05-18

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
    [switch]$SkipSharePointUpload,

    [Parameter(Mandatory = $false, HelpMessage = "Lookback window for non-interactive sign-in logs (D1, D7, D14, D30)")]
    [ValidateSet('D1', 'D7', 'D14', 'D30')]
    [string]$NonInteractiveDaysBack = 'D30',

    [Parameter(Mandatory = $false, HelpMessage = "Number of parallel time-window chunks for non-interactive sign-in queries (1-10)")]
    [ValidateRange(1, 10)]
    [int]$NonInteractiveParallelism = 5
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
    param (
        [int]$DaysBack,
        [int]$NonInteractiveDaysBack,
        [int]$NonInteractiveParallelism
    )

    Write-Log "Querying Teams sign-in logs: interactive last $DaysBack day(s), non-interactive last $NonInteractiveDaysBack day(s) in $NonInteractiveParallelism parallel chunk(s)..."

    $teamsAppId   = '1fec8e78-bce4-4aaf-ab1b-5451cc387264'
    $filterBase   = "appId eq '$teamsAppId' and status/errorCode eq 0"
    $selectFields = 'userId,createdDateTime,deviceDetail'
    $now          = (Get-Date).ToUniversalTime()
    $totalRecords = 0
    $stopwatch    = [System.Diagnostics.Stopwatch]::StartNew()

    # Both sign-in types use the /signIns endpoint (beta required for signInEventTypes filter).
    # Non-interactive sign-ins are filtered via signInEventTypes/any(t: t eq 'nonInteractiveUser').
    # Ref: https://learn.microsoft.com/entra/identity/monitoring-health/howto-analyze-activity-logs-with-microsoft-graph
    #
    # The beta sign-in endpoint's skip token expires after ~7 minutes regardless of page count.
    # Cursor-based recovery: on skip-token expiry, rebuild the query from the last successfully
    # processed createdDateTime. $orderby=createdDateTime asc ensures stable chronological order.
    # Records at the exact cursor timestamp may be re-processed on resume; this is harmless
    # because the max-timestamp tracking per user is idempotent.
    #
    # The NI window is divided into $NonInteractiveParallelism equal time slices, each queried
    # by a dedicated thread job. The interactive job runs concurrently. All jobs merge into
    # two dictionaries (Desktop, Mobile) — the Interactive/Non-Interactive distinction is not
    # preserved, since only per-device last-login is required.

    # 1 interactive source + N NI time-window chunks, all run in parallel.
    $allSources = [System.Collections.Generic.List[hashtable]]::new()

    $allSources.Add(@{
        Label       = 'Interactive'
        BaseUri     = 'https://graph.microsoft.com/v1.0/auditLogs/signIns'
        ExtraFilter = ''
        StartDate   = $now.AddDays(-$DaysBack).ToString('yyyy-MM-ddTHH:mm:ssZ')
        EndDate     = $null
    })

    $chunkDays = $NonInteractiveDaysBack / $NonInteractiveParallelism
    for ($i = 0; $i -lt $NonInteractiveParallelism; $i++) {
        # Chunk 0 is the most recent slice; chunk N-1 is the oldest.
        $chunkEnd   = $now.AddDays(-($i       * $chunkDays))
        $chunkStart = $now.AddDays(-(($i + 1) * $chunkDays))
        $allSources.Add(@{
            Label       = "Non-Interactive ($($i+1)/$NonInteractiveParallelism)"
            BaseUri     = 'https://graph.microsoft.com/beta/auditLogs/signIns'
            ExtraFilter = " and signInEventTypes/any(t: t eq 'nonInteractiveUser')"
            StartDate   = $chunkStart.ToString('yyyy-MM-ddTHH:mm:ssZ')
            # Most-recent chunk has no upper bound; all others end at the chunk boundary.
            EndDate     = if ($i -eq 0) { $null } else { $chunkEnd.ToString('yyyy-MM-ddTHH:mm:ssZ') }
        })
    }

    # Thread job runspaces don't share the Graph module's per-runspace auth session.
    # Extract a raw Bearer token once so each job can call the Graph REST API directly
    # via Invoke-RestMethod without needing Connect-MgGraph inside the runspace.
    Write-Log "Extracting Graph Bearer token for parallel thread jobs..."
    $tokenProbe  = Invoke-MgGraphRequest `
        -Uri "https://graph.microsoft.com/v1.0/users?`$top=1&`$select=id" `
        -OutputType HttpResponseMessage -ErrorAction Stop
    $accessToken = $tokenProbe.RequestMessage.Headers.Authorization.Parameter
    $tokenProbe.Dispose()

    if ([string]::IsNullOrWhiteSpace($accessToken)) {
        throw "Unable to extract Bearer token from Graph response. Ensure Microsoft.Graph.Authentication 2.x is installed."
    }

    # Snapshot script-scope variable into function scope so $using: can capture it.
    $localMobileOSList = $MobileOSList

    # Launch both queries concurrently in thread jobs (same process, isolated runspaces).
    # $using: captures variables from the calling scope without type coercion — more
    # reliable than -ArgumentList with typed param() declarations across runspaces.
    # Each job outputs a [PSCustomObject] directly to the pipeline (implicit output is
    # safer than 'return @{...}' for scriptblocks — avoids early-exit silent drop).
    Write-Log "Launching $($allSources.Count) parallel sign-in query jobs (1 interactive + $NonInteractiveParallelism NI chunks)..."
    $jobs = [System.Collections.Generic.List[object]]::new()
    foreach ($source in $allSources) {
        $capturedSource = $source   # Capture loop variable; $using: reads the value at job start.
        $jobs.Add((Start-ThreadJob -Name "SignIn_$($capturedSource.Label)" -ScriptBlock {
            $src          = $using:capturedSource
            $filterBase   = $using:filterBase
            $selectFields = $using:selectFields
            $mobileOSList = $using:localMobileOSList
            $accessToken  = $using:accessToken

            # Builds a fresh query URI anchored at $fromStr.
            # $src.EndDate (if set) caps the chunk to its time slice; omitted on the most-recent chunk.
            function New-QueryUri ([string]$fromStr) {
                $endClause = if ($src.EndDate) { " and createdDateTime lt $($src.EndDate)" } else { '' }
                $f = "$filterBase and createdDateTime ge $fromStr$endClause$($src.ExtraFilter)"
                "$($src.BaseUri)?`$filter=$([uri]::EscapeDataString($f))&`$orderby=createdDateTime+asc&`$select=$selectFields&`$top=999"
            }

            $desktop   = [System.Collections.Generic.Dictionary[string, System.DateTimeOffset]]::new()
            $mobile    = [System.Collections.Generic.Dictionary[string, System.DateTimeOffset]]::new()
            $count         = 0
            $retries       = 0
            $throttleCount = 0
            $cursorStr = $src.StartDate
            $headers   = @{ Authorization = "Bearer $accessToken" }
            $uri       = New-QueryUri $cursorStr

            while ($true) {
                $response = $null
                try {
                    $response = Invoke-RestMethod -Uri $uri -Headers $headers -Method GET -ErrorAction Stop
                    $throttleCount = 0   # Reset consecutive throttle counter on success.
                }
                catch {
                    $msg = $_.ToString()

                    # 429 Too Many Requests — respect Retry-After header, then retry same URI.
                    if ($msg -like '*429*' -or $msg -like '*Too Many Requests*') {
                        if ($throttleCount -ge 10) { throw "Graph API throttling persisted after 10 consecutive retries." }
                        $throttleCount++
                        $retryAfter = 60   # Conservative default; overridden by Retry-After header when present.
                        try {
                            $delta = $_.Exception.Response?.Headers?.RetryAfter?.Delta
                            if ($null -ne $delta) { $retryAfter = [int]$delta.TotalSeconds + 5 }
                        }
                        catch { }
                        Start-Sleep -Seconds $retryAfter
                        continue   # Retry the same $uri; cursor has not advanced.
                    }

                    if ($msg -notlike '*Skip token*' -and $msg -notlike '*skipToken*') { throw }
                    # Skip token expired — resume from cursor without losing progress.
                    $retries++
                    $uri = New-QueryUri $cursorStr
                    continue
                }

                foreach ($record in $response.value) {
                    $count++
                    $userId = $record.userId
                    if ([string]::IsNullOrWhiteSpace($userId)) { continue }

                    # Parse once; reuse for both login time and cursor advancement.
                    [System.DateTimeOffset]$loginTime = [System.DateTimeOffset]::Parse($record.createdDateTime)
                    $ts = $loginTime.ToString('yyyy-MM-ddTHH:mm:ssZ')
                    if ($ts -gt $cursorStr) { $cursorStr = $ts }

                    $os = $null
                    if ($null -ne $record.deviceDetail) { $os = $record.deviceDetail.operatingSystem }
                    # Browser/web client sign-ins report no OS; treat as Desktop.
                    if ([string]::IsNullOrWhiteSpace($os)) { $os = 'Web' }

                    $dict = if ($os -in $mobileOSList) { $mobile } else { $desktop }
                    [System.DateTimeOffset]$existing = [System.DateTimeOffset]::MinValue
                    if (-not $dict.TryGetValue($userId, [ref]$existing) -or $loginTime -gt $existing) {
                        $dict[$userId] = $loginTime
                    }
                }

                # PSObject.Properties lookup avoids strict-mode error when @odata.nextLink is absent.
                $nextLink = $response.PSObject.Properties['@odata.nextLink']?.Value
                if (-not $nextLink) { break }
                $uri = $nextLink
            }

            # Implicit pipeline output — more reliable than 'return @{...}' for thread job scriptblocks.
            [PSCustomObject]@{
                Label   = $src.Label
                Desktop = $desktop
                Mobile  = $mobile
                Count   = $count
                Retries = $retries
            }
        }))
    }

    # Poll until all jobs finish, showing combined progress on the main thread.
    try {
        while ($jobs | Where-Object { $_.State -eq 'Running' }) {
            $elapsed = [math]::Round($stopwatch.Elapsed.TotalSeconds, 0)
            $done    = ($jobs | Where-Object { $_.State -notin 'Running', 'NotStarted' }).Count
            Write-Progress -Activity 'Processing Teams sign-in logs' `
                -Status "$done/$($jobs.Count) parallel queries complete (${elapsed}s elapsed)" `
                -PercentComplete (($done / $jobs.Count) * 100)
            Start-Sleep -Milliseconds 2000
        }
    }
    finally {
        Write-Progress -Activity 'Processing Teams sign-in logs' -Completed
        $stopwatch.Stop()
    }

    # Collect results; merge all jobs into two dictionaries (Desktop, Mobile).
    # All sign-in types (interactive + every NI chunk) contribute to the same max-timestamp
    # per user per device category — Interactive/Non-Interactive is not distinguished.
    $desktop = [System.Collections.Generic.Dictionary[string, System.DateTimeOffset]]::new()
    $mobile  = [System.Collections.Generic.Dictionary[string, System.DateTimeOffset]]::new()

    foreach ($job in $jobs) {
        $jobErrors = @()
        $result    = Receive-Job -Job $job -Wait -ErrorVariable jobErrors -ErrorAction SilentlyContinue
        $jobName   = $job.Name
        $jobState  = $job.State
        Remove-Job -Job $job -Force -ErrorAction SilentlyContinue

        if ($null -eq $result -or $jobState -eq 'Failed') {
            $errMsg = if ($jobErrors.Count -gt 0) {
                $jobErrors[0].Exception?.Message ?? $jobErrors[0].ToString()
            } else {
                "Job '$jobName' ($jobState) completed with no output. Check that the Bearer token is valid and the account has AuditLog.Read.All."
            }
            Write-Log "Sign-in query job '$jobName' failed: $errMsg" -Level Error
            throw $errMsg
        }

        if ($result.Retries -gt 0) {
            Write-Log "  [$($result.Label)] Skip-token expired and was recovered $($result.Retries) time(s)." -Level Warning
        }

        $totalRecords += $result.Count
        Write-Log "$($result.Label) complete. Records: $($result.Count)."

        # Merge this job's Desktop results (keep max timestamp per user).
        foreach ($kvp in $result.Desktop.GetEnumerator()) {
            [System.DateTimeOffset]$existing = [System.DateTimeOffset]::MinValue
            if (-not $desktop.TryGetValue($kvp.Key, [ref]$existing) -or $kvp.Value -gt $existing) {
                $desktop[$kvp.Key] = $kvp.Value
            }
        }
        # Merge this job's Mobile results (keep max timestamp per user).
        foreach ($kvp in $result.Mobile.GetEnumerator()) {
            [System.DateTimeOffset]$existing = [System.DateTimeOffset]::MinValue
            if (-not $mobile.TryGetValue($kvp.Key, [ref]$existing) -or $kvp.Value -gt $existing) {
                $mobile[$kvp.Key] = $kvp.Value
            }
        }
    }

    Write-Log "Total sign-in records processed: $totalRecords."
    Write-Log "Users with Teams Desktop activity : $($desktop.Count)"
    Write-Log "Users with Teams Mobile activity  : $($mobile.Count)"

    return @{
        Desktop = $desktop
        Mobile  = $mobile
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

        [System.DateTimeOffset]$dtExisting = [System.DateTimeOffset]::MinValue
        $desktopLogin = if ($SignInData.Desktop.TryGetValue($uid, [ref]$dtExisting)) { $dtExisting.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }
        $mobileLogin  = if ($SignInData.Mobile.TryGetValue($uid,  [ref]$dtExisting)) { $dtExisting.UtcDateTime.ToString('yyyy-MM-dd HH:mm:ss') } else { $null }

        $results.Add([PSCustomObject]@{
            DisplayName              = $user.DisplayName
            Email                    = if ($user.Mail) { $user.Mail } else { $user.UserPrincipalName }
            UserPrincipalName        = $user.UserPrincipalName
            OfficeLocation           = $user.OfficeLocation
            Department               = $user.Department
            Title                    = $user.JobTitle
            AccountEnabled           = $user.AccountEnabled
            TeamsDesktopLastLogin_UTC = $desktopLogin
            TeamsMobileLastLogin_UTC  = $mobileLogin
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

Write-Log "=== Get-TeamsActivityLog v2.7.0 ==="
Write-Log "Start Time      : $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Log "Days Back       : $DaysBack (interactive)"
Write-Log "NI Days Back    : $NonInteractiveDaysBack in $NonInteractiveParallelism parallel chunk(s)"
Write-Log "Report Dir      : $ReportBaseDir"

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

    $niDays        = [int]$NonInteractiveDaysBack.TrimStart('D')
    $signInData    = Get-TeamsSignInData -DaysBack $DaysBack -NonInteractiveDaysBack $niDays -NonInteractiveParallelism $NonInteractiveParallelism
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
