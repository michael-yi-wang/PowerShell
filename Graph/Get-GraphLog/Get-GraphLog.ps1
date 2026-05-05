<#
.SYNOPSIS
    Get-GraphLog.ps1 - Interactive Microsoft 365 Audit Log Retrieval Tool for Helpdesk Agents.

.DESCRIPTION
    Connects to Microsoft 365 via app-only authentication and provides an interactive menu
    to retrieve unified audit logs for Exchange Online, SharePoint, OneDrive, and Teams.
    Uses the Microsoft Graph Security Audit Log API (beta endpoint).

    Supported searches:
      - Exchange Online : Mailbox audit events by user UPN (owner, delegate, admin logon types)
      - SharePoint      : Site activity by site URL
      - OneDrive        : User drive activity by UPN or drive URL
      - Microsoft Teams : Team activity by team name (keyword search)

    Results are expanded from raw JSON, stripped of noise, previewed on screen, and exported to CSV.
    All sessions are written to a timestamped log file under the logs/ subfolder.

.PARAMETER TenantId
    The Microsoft 365 Tenant ID (GUID or domain, e.g. contoso.onmicrosoft.com).

.PARAMETER ClientId
    The Azure AD App Registration Client ID (Application ID).

.PARAMETER CertificateThumbprint
    Thumbprint of the certificate already imported in the local store (Cert:\CurrentUser\My).
    Preferred method — no password prompt at runtime.
    Mutually exclusive with -CertificatePath.

.PARAMETER CertificatePath
    Path to a .pfx certificate file.
    Use when the certificate has not yet been imported into the local store.
    Mutually exclusive with -CertificateThumbprint.

.PARAMETER CertificatePassword
    Password for the .pfx file (SecureString). Only used with -CertificatePath.
    Will be prompted interactively if not supplied.

.EXAMPLE
    # Recommended: certificate already imported into local store
    .\Get-GraphLog.ps1 -TenantId "contoso.onmicrosoft.com" -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -CertificateThumbprint "A1B2C3D4E5F6..."

.EXAMPLE
    # Alternative: load certificate directly from a .pfx file
    .\Get-GraphLog.ps1 -TenantId "contoso.onmicrosoft.com" -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -CertificatePath "C:\Certs\M365AuditLogHelpdesk.pfx"

.NOTES
    Required Azure AD Application Permissions (app-only):
      - AuditLog.Read.All

    Authentication:
      App-only certificate authentication (X.509).
      Public key (.cer) is uploaded to the Entra ID app registration.
      Private key (.pfx) is distributed to each helpdesk agent machine.

    Supported PowerShell : 7.x (cross-platform)
    Required Module      : Microsoft.Graph.Authentication
                           Install-Module Microsoft.Graph -Scope CurrentUser

    Graph API            : https://graph.microsoft.com/beta/security/auditLog/queries (beta)

    Known Limitations:
      - Audit log retention is 90 days (standard) or 1 year (E5 / Purview Audit Premium).
      - Query results can take up to 10 minutes to process server-side.
      - Results are paginated at 1,000 records per page; all pages are retrieved automatically.
      - Teams search uses keyword matching; results may include partial name matches.
      - The /beta endpoint may change without notice.

    Author  : Michael Wang
    Version : 1.1
    Date    : 2026-05-05
#>

#Requires -Version 7.0

param (
    [Parameter(Mandatory = $true)]
    [string]$TenantId,

    [Parameter(Mandatory = $true)]
    [string]$ClientId,

    # Certificate already imported in the local store — preferred for shared deployments
    [Parameter(Mandatory = $true, ParameterSetName = 'Thumbprint')]
    [string]$CertificateThumbprint,

    # Certificate loaded from a .pfx file — use when cert is not yet in the local store
    [Parameter(Mandatory = $true, ParameterSetName = 'PfxFile')]
    [string]$CertificatePath,

    [Parameter(Mandatory = $false, ParameterSetName = 'PfxFile')]
    [securestring]$CertificatePassword
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# ─── Paths ───────────────────────────────────────────────────────────────────

$ScriptRoot = $PSScriptRoot
$LogDir     = Join-Path $ScriptRoot 'logs'
$RunStamp   = Get-Date -Format 'yyyyMMddHHmmss'
$LogFile    = Join-Path $LogDir "GraphLog_$RunStamp.log"
$OutputDir  = Join-Path $ScriptRoot 'outputs'

# ─── Audit Record Type Constants ─────────────────────────────────────────────

$ExchangeRecordTypes = @(
    'exchangeItem',
    'exchangeItemGroup',
    'exchangeAdmin',
    'exchangeSearch'
)

$SharePointRecordTypes = @(
    'sharePoint',
    'sharePointFileOperation',
    'sharePointListItemOperation',
    'sharePointSharingOperation',
    'sharePointCommentOperation',
    'sharePointListOperation',
    'sharePointSearch'
)

$OneDriveRecordTypes = @('oneDrive')

$TeamsRecordTypes = @(
    'microsoftTeams',
    'microsoftTeamsAdmin'
)

# Exchange mailbox logon type mapping (value in AuditData.LogonType)
$ExchangeLogonTypeMap = @{
    0 = 'Owner'
    1 = 'Admin'
    2 = 'Delegate'
}

# Query polling configuration
$QueryPollInterval = 10   # seconds between status checks
$MaxPollAttempts   = 60   # 60 * 10s = 10 minutes max wait


# ═════════════════════════════════════════════════════════════════════════════
# region  LOGGING
# ═════════════════════════════════════════════════════════════════════════════

function Write-Log {
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $Timestamp  = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $Entry      = "[$Timestamp] [$Level] $Message"
    $Color      = switch ($Level) {
        'Info'    { 'Green'  }
        'Warning' { 'Yellow' }
        'Error'   { 'Red'    }
    }
    Write-Host $Entry -ForegroundColor $Color
    $Entry | Out-File -FilePath $LogFile -Append -Encoding utf8
}

# endregion


# ═════════════════════════════════════════════════════════════════════════════
# region  INITIALIZATION & AUTHENTICATION
# ═════════════════════════════════════════════════════════════════════════════

function Initialize-Environment {
    if (-not (Test-Path $LogDir)) {
        New-Item -ItemType Directory -Path $LogDir -Force | Out-Null
    }

    if (-not (Test-Path $OutputDir)) {
        New-Item -ItemType Directory -Path $OutputDir -Force | Out-Null
    }

    # Verify required module is available
    if (-not (Get-Module -ListAvailable -Name 'Microsoft.Graph.Authentication')) {
        Write-Log "Module 'Microsoft.Graph.Authentication' not found." -Level Error
        Write-Log "Install it with: Install-Module Microsoft.Graph -Scope CurrentUser" -Level Error
        throw 'Missing required module: Microsoft.Graph.Authentication'
    }

    Import-Module Microsoft.Graph.Authentication -ErrorAction Stop
    Write-Log 'Environment initialized successfully.'
}

function Connect-ToGraph {
    Write-Log "Connecting to Microsoft Graph (Tenant: $TenantId, ClientId: $ClientId)..."

    try {
        if ($PSBoundParameters.ContainsKey('CertificateThumbprint')) {
            Write-Log "Authenticating with certificate thumbprint: $CertificateThumbprint"
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -CertificateThumbprint $CertificateThumbprint -NoWelcome -ErrorAction Stop
        }
        else {
            if (-not (Test-Path $CertificatePath)) {
                throw "Certificate file not found: $CertificatePath"
            }
            if (-not $Script:CertificatePassword) {
                $Script:CertificatePassword = Read-Host -Prompt 'Enter certificate (.pfx) password' -AsSecureString
            }
            Write-Log "Loading certificate from file: $CertificatePath"
            $Cert = [System.Security.Cryptography.X509Certificates.X509Certificate2]::new(
                (Resolve-Path $CertificatePath).Path,
                $Script:CertificatePassword,
                [System.Security.Cryptography.X509Certificates.X509KeyStorageFlags]::EphemeralKeySet
            )
            Connect-MgGraph -TenantId $TenantId -ClientId $ClientId `
                -Certificate $Cert -NoWelcome -ErrorAction Stop
        }
        Write-Log 'Successfully connected to Microsoft Graph.'
    }
    catch {
        Write-Log "Connection failed: $($_.Exception.Message)" -Level Error
        throw
    }
}

# endregion


# ═════════════════════════════════════════════════════════════════════════════
# region  DATE RANGE INPUT
# ═════════════════════════════════════════════════════════════════════════════

function Get-DateRange {
    $DefaultStart = (Get-Date).Date.AddDays(-7)
    $DefaultEnd   = (Get-Date).Date.AddDays(1).AddSeconds(-1)

    Write-Host ''
    Write-Host '  Enter date range (press Enter to accept the default shown in brackets)' -ForegroundColor Cyan

    $StartInput = Read-Host "  Start date [$(Get-Date $DefaultStart -Format 'yyyy-MM-dd')]"
    $EndInput   = Read-Host "  End date   [$(Get-Date $DefaultEnd   -Format 'yyyy-MM-dd')]"

    try {
        $StartDate = if ([string]::IsNullOrWhiteSpace($StartInput)) {
            $DefaultStart
        } else {
            [datetime]::Parse($StartInput)
        }

        $EndDate = if ([string]::IsNullOrWhiteSpace($EndInput)) {
            $DefaultEnd
        } else {
            # Treat entered date as end-of-day
            [datetime]::Parse($EndInput).Date.AddDays(1).AddSeconds(-1)
        }
    }
    catch {
        Write-Log "Invalid date format. Use yyyy-MM-dd (e.g. 2026-04-01)." -Level Error
        return $null
    }

    if ($StartDate -gt $EndDate) {
        Write-Log 'Start date cannot be after end date.' -Level Error
        return $null
    }

    $DaySpan = ($EndDate - $StartDate).Days
    if ($DaySpan -gt 90) {
        Write-Log "WARNING: Date range spans $DaySpan days. Standard audit log retention is 90 days. Extend to 1 year requires Microsoft Purview Audit Premium (E5)." -Level Warning
    }

    Write-Log "Date range: $(Get-Date $StartDate -Format 'yyyy-MM-dd') to $(Get-Date $EndDate -Format 'yyyy-MM-dd') ($DaySpan days)"
    return @{ Start = $StartDate; End = $EndDate }
}

# endregion


# ═════════════════════════════════════════════════════════════════════════════
# region  GRAPH AUDIT LOG QUERY ENGINE
# ═════════════════════════════════════════════════════════════════════════════

function Invoke-AuditLogQuery {
    param (
        [Parameter(Mandatory = $true)]
        [hashtable]$QueryBody
    )

    $Uri  = 'https://graph.microsoft.com/beta/security/auditLog/queries'
    $Json = $QueryBody | ConvertTo-Json -Depth 5

    Write-Log "Submitting audit log query: $($QueryBody.displayName)"

    try {
        $Response = Invoke-MgGraphRequest -Method POST -Uri $Uri -Body $Json -ContentType 'application/json'
        Write-Log "Query submitted successfully. Query ID: $($Response.id)"
        return $Response
    }
    catch {
        Write-Log "Failed to submit query: $($_.Exception.Message)" -Level Error
        throw
    }
}

function Wait-ForQueryCompletion {
    param (
        [Parameter(Mandatory = $true)]
        [string]$QueryId
    )

    $Uri      = "https://graph.microsoft.com/beta/security/auditLog/queries/$QueryId"
    $Attempts = 0

    Write-Log 'Waiting for query to complete (this may take several minutes)...'
    Write-Log "NOTE: If the query does not complete in $($MaxPollAttempts * $QueryPollInterval / 60) minutes, narrow your date range and try again." -Level Warning
    Write-Host ''

    do {
        Start-Sleep -Seconds $QueryPollInterval
        $Attempts++

        try {
            $Status = Invoke-MgGraphRequest -Method GET -Uri $Uri
        }
        catch {
            Write-Host ''
            Write-Log "Error polling query status: $($_.Exception.Message)" -Level Error
            return $null
        }

        Write-Host "`r  [ Status: $($Status.status.PadRight(12)) | Elapsed: $($Attempts * $QueryPollInterval)s ]" -NoNewline

        if ($Status.status -eq 'failed') {
            Write-Host ''
            Write-Log "Query failed on the server side. Try a narrower date range or fewer record type filters." -Level Error
            return $null
        }

        if ($Attempts -ge $MaxPollAttempts) {
            Write-Host ''
            Write-Log "Query timed out after $($MaxPollAttempts * $QueryPollInterval / 60) minutes. The query is still running on the server; try narrowing the date range." -Level Warning
            return $null
        }

    } while ($Status.status -notin @('succeeded', 'failed'))

    Write-Host ''
    Write-Log "Query completed with status: $($Status.status)"
    return $Status
}

function Get-AuditLogRecords {
    param (
        [Parameter(Mandatory = $true)]
        [string]$QueryId
    )

    $Records   = [System.Collections.Generic.List[object]]::new()
    $Uri       = "https://graph.microsoft.com/beta/security/auditLog/queries/$QueryId/records"
    $PageIndex = 0

    Write-Log 'Retrieving audit log records...'

    do {
        $PageIndex++
        $Response = Invoke-MgGraphRequest -Method GET -Uri $Uri

        if ($Response.value -and $Response.value.Count -gt 0) {
            foreach ($Record in $Response.value) {
                $Records.Add($Record)
            }
            Write-Log "  Page $PageIndex : $($Response.value.Count) records (running total: $($Records.Count))"
        }

        $Uri = $Response.'@odata.nextLink'

        if ($null -ne $Uri) {
            Write-Log "WARNING: Result set has more than $($Records.Count) records. Fetching next page..." -Level Warning
        }

    } while ($null -ne $Uri)

    if ($Records.Count -eq 0) {
        Write-Log 'No audit records found for the specified criteria. Verify the UPN/URL/name and date range.' -Level Warning
    }
    else {
        Write-Log "Total records retrieved: $($Records.Count)"
    }

    return $Records
}

# endregion


# ═════════════════════════════════════════════════════════════════════════════
# region  AUDITDATA HELPERS
# ═════════════════════════════════════════════════════════════════════════════

function Expand-AuditData {
    param ([object]$AuditData)

    if ($null -eq $AuditData) { return @{} }

    # String → parse as JSON
    if ($AuditData -is [string]) {
        if ([string]::IsNullOrWhiteSpace($AuditData)) { return @{} }
        try   { return $AuditData | ConvertFrom-Json -AsHashtable -ErrorAction Stop }
        catch { return @{ RawData = $AuditData } }
    }

    # Already a dictionary (returned by Invoke-MgGraphRequest)
    if ($AuditData -is [System.Collections.IDictionary]) { return $AuditData }

    # PSCustomObject → convert to hashtable
    if ($AuditData -is [PSCustomObject]) {
        $ht = @{}
        foreach ($p in $AuditData.PSObject.Properties) { $ht[$p.Name] = $p.Value }
        return $ht
    }

    return @{ RawData = [string]$AuditData }
}

function Get-SafeValue {
    # Returns a string value from a hashtable/PSObject using case-insensitive key lookup.
    # Complex objects (arrays, nested hashtables) are serialized to compact JSON.
    param (
        [object]$Data,
        [string]$Key,
        [string]$Default = ''
    )

    if ($null -eq $Data) { return $Default }

    $val = $null
    $found = $false

    if ($Data -is [System.Collections.IDictionary]) {
        foreach ($k in $Data.Keys) {
            if ($k -ieq $Key) { $val = $Data[$k]; $found = $true; break }
        }
    }
    else {
        $prop = $Data.PSObject.Properties | Where-Object { $_.Name -ieq $Key } | Select-Object -First 1
        if ($null -ne $prop) { $val = $prop.Value; $found = $true }
    }

    if (-not $found -or $null -eq $val) { return $Default }
    if ($val -is [string]) { return $val }
    if ($val -is [bool] -or $val -is [int] -or $val -is [long] -or $val -is [double]) { return [string]$val }

    # Complex value → compact JSON for readability in CSV
    try   { return $val | ConvertTo-Json -Compress -Depth 4 }
    catch { return [string]$val }
}

function Get-RecordField {
    # Reads a field directly from a record hashtable (Graph API response).
    param ([object]$Record, [string]$Key, [string]$Default = '')
    return Get-SafeValue -Data $Record -Key $Key -Default $Default
}

# endregion


# ═════════════════════════════════════════════════════════════════════════════
# region  SERVICE-SPECIFIC RECORD FORMATTERS
# ═════════════════════════════════════════════════════════════════════════════

function Format-ExchangeRecord {
    param ([object]$Record)

    $AD = Expand-AuditData (Get-RecordField -Record $Record -Key 'auditData')

    # Resolve logon type to human-readable string
    $LogonTypeRaw = Get-SafeValue -Data $AD -Key 'LogonType'
    $LogonType = if ($LogonTypeRaw -ne '') {
        $lt = [int]$LogonTypeRaw
        if ($ExchangeLogonTypeMap.ContainsKey($lt)) { $ExchangeLogonTypeMap[$lt] } else { "Unknown ($lt)" }
    }
    else { '' }

    # InternalLogonType is the same as LogonType in some record variants
    if ($LogonType -eq '' ) {
        $InternalRaw = Get-SafeValue -Data $AD -Key 'InternalLogonType'
        if ($InternalRaw -ne '') {
            $lt = [int]$InternalRaw
            $LogonType = if ($ExchangeLogonTypeMap.ContainsKey($lt)) { $ExchangeLogonTypeMap[$lt] } else { "Unknown ($lt)" }
        }
    }

    [PSCustomObject]@{
        DateTime        = Get-RecordField -Record $Record -Key 'createdDateTime'
        Service         = 'Exchange Online'
        RecordType      = Get-RecordField -Record $Record -Key 'auditLogRecordType'
        Operation       = Get-RecordField -Record $Record -Key 'operationName'
        LogonType       = $LogonType
        UserId          = Get-RecordField -Record $Record -Key 'userId'
        MailboxOwnerUPN = Get-SafeValue   -Data $AD       -Key 'MailboxOwnerUPN'
        ClientIP        = Get-RecordField -Record $Record -Key 'clientIp'
        ClientInfo      = Get-SafeValue   -Data $AD       -Key 'ClientInfoString'
        ExternalAccess  = Get-SafeValue   -Data $AD       -Key 'ExternalAccess'
        FolderPath      = Get-SafeValue   -Data $AD       -Key 'FolderPathName'
        ItemSubject     = Get-SafeValue   -Data $AD       -Key 'ItemSubject'
        AffectedItems   = Get-SafeValue   -Data $AD       -Key 'AffectedItems'
        ResultStatus    = Get-SafeValue   -Data $AD       -Key 'ResultStatus'
        ObjectId        = Get-RecordField -Record $Record -Key 'objectId'
    }
}

function Format-SharePointRecord {
    param ([object]$Record)

    $AD = Expand-AuditData (Get-RecordField -Record $Record -Key 'auditData')

    [PSCustomObject]@{
        DateTime    = Get-RecordField -Record $Record -Key 'createdDateTime'
        Service     = 'SharePoint'
        RecordType  = Get-RecordField -Record $Record -Key 'auditLogRecordType'
        Operation   = Get-RecordField -Record $Record -Key 'operationName'
        UserId      = Get-RecordField -Record $Record -Key 'userId'
        SiteUrl     = Get-SafeValue   -Data $AD       -Key 'SiteUrl'
        WebUrl      = Get-SafeValue   -Data $AD       -Key 'WebUrl'
        ItemType    = Get-SafeValue   -Data $AD       -Key 'ItemType'
        FileName    = Get-SafeValue   -Data $AD       -Key 'SourceFileName'
        FilePath    = Get-SafeValue   -Data $AD       -Key 'SourceRelativeUrl'
        EventSource = Get-SafeValue   -Data $AD       -Key 'EventSource'
        UserAgent   = Get-SafeValue   -Data $AD       -Key 'UserAgent'
        ClientIP    = Get-RecordField -Record $Record -Key 'clientIp'
        ObjectId    = Get-RecordField -Record $Record -Key 'objectId'
    }
}

function Format-OneDriveRecord {
    param ([object]$Record)

    $AD = Expand-AuditData (Get-RecordField -Record $Record -Key 'auditData')

    [PSCustomObject]@{
        DateTime      = Get-RecordField -Record $Record -Key 'createdDateTime'
        Service       = 'OneDrive'
        RecordType    = Get-RecordField -Record $Record -Key 'auditLogRecordType'
        Operation     = Get-RecordField -Record $Record -Key 'operationName'
        UserId        = Get-RecordField -Record $Record -Key 'userId'
        SiteUrl       = Get-SafeValue   -Data $AD       -Key 'SiteUrl'
        FileName      = Get-SafeValue   -Data $AD       -Key 'SourceFileName'
        FilePath      = Get-SafeValue   -Data $AD       -Key 'SourceRelativeUrl'
        FileSizeBytes = Get-SafeValue   -Data $AD       -Key 'FileSizeBytes'
        UserAgent     = Get-SafeValue   -Data $AD       -Key 'UserAgent'
        ClientIP      = Get-RecordField -Record $Record -Key 'clientIp'
        ObjectId      = Get-RecordField -Record $Record -Key 'objectId'
    }
}

function Format-TeamsRecord {
    param ([object]$Record)

    $AD = Expand-AuditData (Get-RecordField -Record $Record -Key 'auditData')

    [PSCustomObject]@{
        DateTime          = Get-RecordField -Record $Record -Key 'createdDateTime'
        Service           = 'Microsoft Teams'
        RecordType        = Get-RecordField -Record $Record -Key 'auditLogRecordType'
        Operation         = Get-RecordField -Record $Record -Key 'operationName'
        UserId            = Get-RecordField -Record $Record -Key 'userId'
        TeamName          = Get-SafeValue   -Data $AD       -Key 'TeamName'
        ChannelName       = Get-SafeValue   -Data $AD       -Key 'ChannelName'
        CommunicationType = Get-SafeValue   -Data $AD       -Key 'CommunicationType'
        Members           = Get-SafeValue   -Data $AD       -Key 'Members'
        TabName           = Get-SafeValue   -Data $AD       -Key 'TabName'
        ClientIP          = Get-RecordField -Record $Record -Key 'clientIp'
        ObjectId          = Get-RecordField -Record $Record -Key 'objectId'
    }
}

# endregion


# ═════════════════════════════════════════════════════════════════════════════
# region  EXPORT
# ═════════════════════════════════════════════════════════════════════════════

function Export-Results {
    param (
        [Parameter(Mandatory = $true)]
        [object[]]$Results,

        [Parameter(Mandatory = $true)]
        [string]$Label
    )

    if ($Results.Count -eq 0) { return }

    $SafeLabel = $Label -replace '[/\\:*?"<>|]', '_'
    $OutFile   = Join-Path $OutputDir "${SafeLabel}_${RunStamp}.csv"

    Write-Host ''
    Write-Host '  ── Preview (first 10 records) ───────────────────────────────' -ForegroundColor Cyan
    $Results | Select-Object -First 10 | Format-Table -AutoSize | Out-Host
    Write-Host '  ─────────────────────────────────────────────────────────────' -ForegroundColor Cyan

    Write-Log "Exporting $($Results.Count) record(s) to: $OutFile"
    $Results | Export-Csv -Path $OutFile -NoTypeInformation -Encoding utf8
    Write-Log "Export complete: $OutFile"
    Write-Host "  Saved: $OutFile" -ForegroundColor Cyan
}

# endregion


# ═════════════════════════════════════════════════════════════════════════════
# region  SEARCH WORKFLOWS
# ═════════════════════════════════════════════════════════════════════════════

function Invoke-ExchangeAuditSearch {
    Write-Host ''
    $Upn = (Read-Host '  Enter user UPN (e.g. user@contoso.com)').Trim()
    if ([string]::IsNullOrWhiteSpace($Upn)) {
        Write-Log 'UPN cannot be empty.' -Level Warning
        return
    }

    $DateRange = Get-DateRange
    if ($null -eq $DateRange) { return }

    Write-Log "Exchange audit search — UPN: $Upn"
    Write-Log "NOTE: Includes owner, delegate, and admin access. Check the 'LogonType' column to differentiate." -Level Warning

    $QueryBody = @{
        displayName              = "Exchange-$Upn-$RunStamp"
        filterStartDateTime      = $DateRange.Start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        filterEndDateTime        = $DateRange.End.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        recordTypeFilters        = $ExchangeRecordTypes
        userPrincipalNameFilters = @($Upn)
    }

    $Query = Invoke-AuditLogQuery -QueryBody $QueryBody
    if ($null -eq $Query) { return }

    $Completed = Wait-ForQueryCompletion -QueryId $Query.id
    if ($null -eq $Completed) { return }

    $Records = Get-AuditLogRecords -QueryId $Query.id
    if ($Records.Count -eq 0) { return }

    $Formatted = @($Records | ForEach-Object { Format-ExchangeRecord -Record $_ })
    Export-Results -Results $Formatted -Label "exchange_$Upn"
}

function Invoke-SharePointAuditSearch {
    Write-Host ''
    $SiteUrl = (Read-Host '  Enter SharePoint site URL (e.g. https://contoso.sharepoint.com/sites/Marketing)').Trim()
    if ([string]::IsNullOrWhiteSpace($SiteUrl)) {
        Write-Log 'Site URL cannot be empty.' -Level Warning
        return
    }

    $DateRange = Get-DateRange
    if ($null -eq $DateRange) { return }

    $SiteUrl   = $SiteUrl.TrimEnd('/')
    $SiteLabel = ($SiteUrl -split '/')[-1]

    Write-Log "SharePoint audit search — Site: $SiteUrl"
    Write-Log "NOTE: objectIdFilters matches on item ObjectId. If results are empty a keyword fallback will run automatically." -Level Warning

    # Primary attempt: filter by objectId (matches items whose ObjectId starts with the site URL)
    $QueryBody = @{
        displayName         = "SPO-$SiteLabel-$RunStamp"
        filterStartDateTime = $DateRange.Start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        filterEndDateTime   = $DateRange.End.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        recordTypeFilters   = $SharePointRecordTypes
        objectIdFilters     = @($SiteUrl)
    }

    $Query = Invoke-AuditLogQuery -QueryBody $QueryBody
    if ($null -eq $Query) { return }

    $Completed = Wait-ForQueryCompletion -QueryId $Query.id
    if ($null -eq $Completed) { return }

    $Records = Get-AuditLogRecords -QueryId $Query.id

    # Fallback: keyword search when objectIdFilters returns nothing
    if ($Records.Count -eq 0) {
        Write-Log 'No results with objectIdFilters. Retrying with keywordFilter against the site URL...' -Level Warning

        $QueryBody2 = @{
            displayName         = "SPO-KW-$SiteLabel-$RunStamp"
            filterStartDateTime = $DateRange.Start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            filterEndDateTime   = $DateRange.End.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
            recordTypeFilters   = $SharePointRecordTypes
            keywordFilter       = $SiteUrl
        }

        $Query2    = Invoke-AuditLogQuery -QueryBody $QueryBody2
        if ($null -eq $Query2) { return }
        $Completed2 = Wait-ForQueryCompletion -QueryId $Query2.id
        if ($null -eq $Completed2) { return }
        $Records    = Get-AuditLogRecords -QueryId $Query2.id
        if ($Records.Count -eq 0) { return }
    }

    $Formatted = @($Records | ForEach-Object { Format-SharePointRecord -Record $_ })
    Export-Results -Results $Formatted -Label "sharepoint_$SiteLabel"
}

function Invoke-OneDriveAuditSearch {
    Write-Host ''
    Write-Host '  Search OneDrive by:' -ForegroundColor Cyan
    Write-Host '  [1] User UPN'
    Write-Host '  [2] OneDrive URL (https://contoso-my.sharepoint.com/personal/...)'
    $SubChoice = (Read-Host '  Select').Trim()

    $QueryBody = @{
        displayName         = ''
        filterStartDateTime = ''
        filterEndDateTime   = ''
        recordTypeFilters   = $OneDriveRecordTypes
    }
    $Label = 'OneDrive'

    if ($SubChoice -eq '1') {
        $Upn = (Read-Host '  Enter user UPN (e.g. user@contoso.com)').Trim()
        if ([string]::IsNullOrWhiteSpace($Upn)) { Write-Log 'UPN cannot be empty.' -Level Warning; return }

        $DateRange = Get-DateRange
        if ($null -eq $DateRange) { return }

        $QueryBody['displayName']              = "OD-$Upn-$RunStamp"
        $QueryBody['filterStartDateTime']      = $DateRange.Start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $QueryBody['filterEndDateTime']        = $DateRange.End.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $QueryBody['userPrincipalNameFilters'] = @($Upn)
        $Label = "onedrive_$Upn"
        Write-Log "OneDrive audit search — UPN: $Upn"
    }
    elseif ($SubChoice -eq '2') {
        $DriveUrl = (Read-Host '  Enter OneDrive URL').Trim()
        if ([string]::IsNullOrWhiteSpace($DriveUrl)) { Write-Log 'URL cannot be empty.' -Level Warning; return }

        $DateRange = Get-DateRange
        if ($null -eq $DateRange) { return }

        $DriveUrl = $DriveUrl.TrimEnd('/')
        $QueryBody['displayName']         = "OD-URL-$RunStamp"
        $QueryBody['filterStartDateTime'] = $DateRange.Start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $QueryBody['filterEndDateTime']   = $DateRange.End.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        $QueryBody['objectIdFilters']     = @($DriveUrl)
        $Label = "onedrive_$($DriveUrl.Split('/')[-1])"
        Write-Log "OneDrive audit search — URL: $DriveUrl"
    }
    else {
        Write-Log 'Invalid selection.' -Level Warning
        return
    }

    $Query = Invoke-AuditLogQuery -QueryBody $QueryBody
    if ($null -eq $Query) { return }

    $Completed = Wait-ForQueryCompletion -QueryId $Query.id
    if ($null -eq $Completed) { return }

    $Records = Get-AuditLogRecords -QueryId $Query.id
    if ($Records.Count -eq 0) { return }

    $Formatted = @($Records | ForEach-Object { Format-OneDriveRecord -Record $_ })
    Export-Results -Results $Formatted -Label $Label
}

function Invoke-TeamsAuditSearch {
    Write-Host ''
    $TeamName = (Read-Host '  Enter team name (partial name supported)').Trim()
    if ([string]::IsNullOrWhiteSpace($TeamName)) {
        Write-Log 'Team name cannot be empty.' -Level Warning
        return
    }

    $DateRange = Get-DateRange
    if ($null -eq $DateRange) { return }

    Write-Log "Teams audit search — Keyword: $TeamName"
    Write-Log "NOTE: Teams search uses keyword matching across team name, channel name, and audit data fields. Partial names may return broader results." -Level Warning

    $QueryBody = @{
        displayName         = "Teams-$TeamName-$RunStamp"
        filterStartDateTime = $DateRange.Start.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        filterEndDateTime   = $DateRange.End.ToUniversalTime().ToString('yyyy-MM-ddTHH:mm:ssZ')
        recordTypeFilters   = $TeamsRecordTypes
        keywordFilter       = $TeamName
    }

    $Query = Invoke-AuditLogQuery -QueryBody $QueryBody
    if ($null -eq $Query) { return }

    $Completed = Wait-ForQueryCompletion -QueryId $Query.id
    if ($null -eq $Completed) { return }

    $Records = Get-AuditLogRecords -QueryId $Query.id
    if ($Records.Count -eq 0) { return }

    $SafeName  = $TeamName -replace '[^a-zA-Z0-9]', '_'
    $Formatted = @($Records | ForEach-Object { Format-TeamsRecord -Record $_ })
    Export-Results -Results $Formatted -Label "teams_$SafeName"
}

# endregion


# ═════════════════════════════════════════════════════════════════════════════
# region  INTERACTIVE MENU
# ═════════════════════════════════════════════════════════════════════════════

function Show-Menu {
    Write-Host ''
    Write-Host '╔═════════════════════════════════════════════════╗' -ForegroundColor Cyan
    Write-Host '║   Microsoft 365 Audit Log Retrieval Tool        ║' -ForegroundColor Cyan
    Write-Host '╠═════════════════════════════════════════════════╣' -ForegroundColor Cyan
    Write-Host '║  [1]  Exchange Online  — by User UPN            ║' -ForegroundColor Cyan
    Write-Host '║  [2]  SharePoint       — by Site URL            ║' -ForegroundColor Cyan
    Write-Host '║  [3]  OneDrive         — by UPN or Drive URL    ║' -ForegroundColor Cyan
    Write-Host '║  [4]  Microsoft Teams  — by Team Name           ║' -ForegroundColor Cyan
    Write-Host '║  [5]  Exit                                      ║' -ForegroundColor Cyan
    Write-Host '╚═════════════════════════════════════════════════╝' -ForegroundColor Cyan
    Write-Host ''
    return (Read-Host '  Select an option [1-5]').Trim()
}

# endregion


# ═════════════════════════════════════════════════════════════════════════════
# region  MAIN
# ═════════════════════════════════════════════════════════════════════════════

try {
    Initialize-Environment
    Write-Log "=== Get-GraphLog session started (Run ID: $RunStamp) ==="
    Connect-ToGraph

    do {
        $Choice = Show-Menu

        switch ($Choice) {
            '1'     { Invoke-ExchangeAuditSearch  }
            '2'     { Invoke-SharePointAuditSearch }
            '3'     { Invoke-OneDriveAuditSearch   }
            '4'     { Invoke-TeamsAuditSearch      }
            '5'     { Write-Log 'User selected Exit.' }
            default { Write-Log "Invalid option '$Choice'. Please enter 1-5." -Level Warning }
        }

    } while ($Choice -ne '5')
}
catch {
    Write-Log "Unhandled error: $($_.Exception.Message)" -Level Error
    Write-Log "Stack trace: $($_.ScriptStackTrace)" -Level Error
}
finally {
    Write-Log 'Disconnecting from Microsoft Graph...'
    try { Disconnect-MgGraph -ErrorAction SilentlyContinue } catch {}
    Write-Log "=== Session ended ==="
}

# endregion
