#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieves Entra Connect Sync errors and uploads a CSV report to SharePoint Online.

.DESCRIPTION
    Queries Microsoft Graph to collect Entra Connect (Azure AD Connect) synchronization
    errors for users, groups, and organizational contacts.

    Errors are categorized to match the Microsoft Entra Connect Health portal's 7 buckets:
      - Duplicate Attribute         : PropertyConflict, AttributeValueMustBeUnique, etc.
      - Data Mismatch               : InvalidSoftMatch, InvalidHardMatch, ObjectTypeMismatch, etc.
      - Data Validation Failure     : DataValidationFailed, ExchangeObjectConflict, etc.
      - Large Attribute             : LargeObject, ExceededAllowedLength.
      - Federated Domain Change     : FederatedDomainChange, InvalidFederatedUser, etc.
      - Existing Admin Role Conflict: AdminRoleConflict, ExistingAdminRole.
      - Other                       : All remaining categories.

    Results are exported to a dated CSV and optionally uploaded to SharePoint Online
    under the path: {DocumentLibrary}/{BaseFolderPath}/{YYYY}/{MMM}/{filename}.csv

    Supports interactive authentication (manual runs) and certificate-based app-only
    authentication (Task Scheduler / unattended runs).

.PARAMETER TenantId
    The Entra ID tenant ID (GUID).

.PARAMETER ClientId
    The App Registration client ID. Required for certificate-based (non-interactive) auth.

.PARAMETER CertificateThumbprint
    Certificate thumbprint for non-interactive authentication.
    Must be installed in the current user or local machine certificate store.

.PARAMETER SharePointSiteUrl
    Full SharePoint Online site URL.
    Example: https://contoso.sharepoint.com/sites/IT

.PARAMETER SharePointDocumentLibrary
    The site-relative URL path of the document library (use the URL name, not display name).
    Example: "Documents" or "Shared%20Documents" -> use "Shared Documents"
    Default: "Documents"

.PARAMETER SharePointBaseFolderPath
    Base folder within the document library. Files are organized under
    {BaseFolderPath}/{YYYY}/{MMM}/
    Default: "Entra Sync Errors"

.PARAMETER OutputPath
    Base directory for output. Reports are written to {OutputPath}\reports\ and logs to
    {OutputPath}\logs\. Both subdirectories are created automatically if they do not exist.
    Default: Directory of this script (or current working directory if run from console).

.PARAMETER SkipSharePointUpload
    Skip uploading to SharePoint. Useful for testing or local-only reports.

.EXAMPLE
    # Interactive (manual) run
    .\Get-EntraSyncErrorUsers.ps1 `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -SharePointSiteUrl "https://contoso.sharepoint.com/sites/IT" `
        -SharePointDocumentLibrary "Documents"

.EXAMPLE
    # Non-interactive run for Task Scheduler
    .\Get-EntraSyncErrorUsers.ps1 `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -ClientId "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
        -CertificateThumbprint "ABCDEF1234567890ABCDEF1234567890ABCDEF12" `
        -SharePointSiteUrl "https://contoso.sharepoint.com/sites/IT" `
        -SharePointDocumentLibrary "Documents" `
        -SharePointBaseFolderPath "Entra Sync Errors"

.EXAMPLE
    # Generate local report only, skip SharePoint upload
    .\Get-EntraSyncErrorUsers.ps1 `
        -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
        -SkipSharePointUpload `
        -OutputPath "C:\Reports"

.NOTES
    Author:  Michael Wang
    Version: 1.2
    Date:    2026-05-25

    Change log:
      1.2 - Set $env:SharePointPnPHttpTimeout = 600 to override PnP.PowerShell's
            hardcoded 100-second HttpClient limit (no -RequestTimeout parameter exists).
            Hardened retry timeout detection to check exception type in addition
            to string matching.
      1.1 - Added 3-attempt retry loop around Add-PnPFile to handle intermittent
            SharePoint upload timeouts (HttpClient.Timeout 100 s default).

    Required Modules:
        Microsoft.Graph.Users
        Microsoft.Graph.Groups
        Microsoft.Graph.Identity.DirectoryManagement
        PnP.PowerShell

    Microsoft Graph API Permissions (Application):
        User.Read.All
        Group.Read.All
        OrgContact.Read.All

    SharePoint Permissions (App Registration):
        SharePoint API (Application): Sites.Selected
        Then grant site-level access: Grant-PnPAzureADAppSitePermission -AppId <ClientId> -DisplayName <Name> -Site <SiteUrl> -Permissions Manage

    Task Scheduler command:
        pwsh.exe -NonInteractive -File "C:\Scripts\Get-EntraSyncErrorUsers.ps1"
            -TenantId "..." -ClientId "..." -CertificateThumbprint "..."
            -SharePointSiteUrl "..." -SharePointDocumentLibrary "..."
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

    [Parameter(Mandatory = $false, HelpMessage = "SharePoint Online site URL")]
    [string]$SharePointSiteUrl,

    [Parameter(Mandatory = $false, HelpMessage = "Document library URL name (not display name)")]
    [string]$SharePointDocumentLibrary = "Documents",

    [Parameter(Mandatory = $false, HelpMessage = "Base folder path within the document library")]
    [string]$SharePointBaseFolderPath = "Entra Sync Errors",

    [Parameter(Mandatory = $false, HelpMessage = "Local directory for output files")]
    [string]$OutputPath,

    [Parameter(Mandatory = $false, HelpMessage = "Skip uploading the report to SharePoint Online")]
    [switch]$SkipSharePointUpload
)

#region Initialization

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

# Resolve output path: prefer script directory, fall back to current location
if ([string]::IsNullOrWhiteSpace($OutputPath)) {
    $OutputPath = if ($PSScriptRoot) { $PSScriptRoot } else { (Get-Location).Path }
}

$reportsPath = Join-Path -Path $OutputPath -ChildPath "reports"
$logsPath    = Join-Path -Path $OutputPath -ChildPath "logs"

foreach ($dir in @($reportsPath, $logsPath)) {
    if (-not (Test-Path -Path $dir -PathType Container)) {
        New-Item -Path $dir -ItemType Directory -Force | Out-Null
    }
}

$scriptStartTime = Get-Date
$datestamp        = $scriptStartTime.ToString("yyyyMMdd")
$timestamp        = $scriptStartTime.ToString("yyyyMMdd_HHmmss")
$yearFolder       = $scriptStartTime.ToString("yyyy")
$monthFolder      = $scriptStartTime.ToString("MMM")

$logFile = Join-Path -Path $logsPath    -ChildPath "Get-EntraSyncErrorUsers_$timestamp.log"
$csvFile = Join-Path -Path $reportsPath -ChildPath "EntraSyncErrors_$datestamp.csv"

#endregion

#region Logging

function Write-Log {
    [CmdletBinding()]
    param (
        [Parameter(Mandatory = $true)]
        [string]$Message,

        [Parameter(Mandatory = $false)]
        [ValidateSet("Info", "Warning", "Error")]
        [string]$Level = "Info"
    )

    $entry = "[{0}] [{1,-7}] {2}" -f (Get-Date -Format "yyyy-MM-dd HH:mm:ss"), $Level, $Message

    switch ($Level) {
        "Info"    { Write-Host $entry -ForegroundColor Green }
        "Warning" { Write-Host $entry -ForegroundColor Yellow }
        "Error"   { Write-Host $entry -ForegroundColor Red }
    }

    Add-Content -Path $logFile -Value $entry -Encoding UTF8
}

#endregion

#region Helper Functions

function Get-SyncErrorCategory {
    <#
    .SYNOPSIS
        Maps a raw Graph API error category string to a human-readable report category.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [AllowEmptyString()]
        [string]$RawCategory
    )

    # Categories mirror the Microsoft Entra Connect Health portal's 7 error buckets.
    # Source: https://learn.microsoft.com/entra/identity/hybrid/connect/how-to-connect-health-sync

    switch ($RawCategory) {
        { $_ -in @("PropertyConflict", "AttributeValueMustBeUnique", "MatchedWithSoftmatch", "GeneratedUpnConflict") } {
            return "Duplicate Attribute"
        }
        { $_ -in @("InvalidSoftMatch", "InvalidHardMatch", "ObjectTypeMismatch", "DomainMismatch") } {
            return "Data Mismatch"
        }
        { $_ -in @("DataValidationFailed", "DataValidationFailure", "DomainNotVerified", "ExchangeObjectConflict", "ExternalGovObjectDataValidationFailure") } {
            return "Data Validation Failure"
        }
        { $_ -in @("LargeObject", "ExceededAllowedLength") } {
            return "Large Attribute"
        }
        { $_ -in @("FederatedDomainChange", "FederatedDomainChangeError", "InvalidFederatedUser") } {
            return "Federated Domain Change"
        }
        { $_ -in @("AdminRoleConflict", "ExistingAdminRole") } {
            return "Existing Admin Role Conflict"
        }
        default {
            return "Other"
        }
    }
}

function ConvertTo-ErrorRows {
    <#
    .SYNOPSIS
        Expands an object's OnPremisesProvisioningErrors into one PSCustomObject per error.
    #>
    param (
        [Parameter(Mandatory = $true)]
        [string]$ObjectType,

        [Parameter(Mandatory = $true)]
        [object]$GraphObject
    )

    $rows = [System.Collections.Generic.List[PSCustomObject]]::new()

    foreach ($provError in $GraphObject.OnPremisesProvisioningErrors) {
        $rows.Add([PSCustomObject]@{
            ObjectType                  = $ObjectType
            ObjectId                    = $GraphObject.Id
            DisplayName                 = $GraphObject.DisplayName
            UserPrincipalName           = if ($ObjectType -eq "User") { $GraphObject.PSObject.Properties['UserPrincipalName']?.Value ?? "" } else { "" }
            Mail                        = $GraphObject.PSObject.Properties['Mail']?.Value ?? ""
            OnPremisesDistinguishedName = $GraphObject.PSObject.Properties['OnPremisesDistinguishedName']?.Value ?? ""
            ErrorCategory               = Get-SyncErrorCategory -RawCategory $provError.Category
            RawErrorCategory            = $provError.Category
            OccurredDateTime            = if ($provError.OccurredDateTime) {
                                              $provError.OccurredDateTime.ToString("yyyy-MM-dd HH:mm:ss")
                                          } else { "" }
            PropertyCausingError        = $provError.PropertyCausingError
            ConflictingValue            = $provError.Value
            AccountEnabled              = if ($ObjectType -eq "User") { $GraphObject.PSObject.Properties['AccountEnabled']?.Value ?? "" } else { "" }
            Department                  = if ($ObjectType -eq "User") { $GraphObject.PSObject.Properties['Department']?.Value ?? "" } else { "" }
            JobTitle                    = if ($ObjectType -eq "User") { $GraphObject.PSObject.Properties['JobTitle']?.Value ?? "" } else { "" }
            OnPremisesImmutableId       = if ($ObjectType -eq "User") { $GraphObject.PSObject.Properties['OnPremisesImmutableId']?.Value ?? "" } else { "" }
        })
    }

    return $rows
}

function Assert-RequiredModule {
    param ([string]$ModuleName)

    if (-not (Get-Module -ListAvailable -Name $ModuleName)) {
        Write-Log -Message "Required module '$ModuleName' is not installed. Run: Install-Module $ModuleName" -Level Error
        throw "Module '$ModuleName' is required but not installed."
    }
}

#endregion

#region Validate Parameters

Write-Log -Message "=== Get-EntraSyncErrorUsers Started ==="
Write-Log -Message "Start Time : $($scriptStartTime.ToString('yyyy-MM-dd HH:mm:ss'))"
Write-Log -Message "Reports Path: $reportsPath"
Write-Log -Message "Logs Path   : $logsPath"

if (-not $SkipSharePointUpload) {
    if ([string]::IsNullOrWhiteSpace($SharePointSiteUrl)) {
        Write-Log -Message "-SharePointSiteUrl is required unless -SkipSharePointUpload is specified." -Level Error
        throw "Missing required parameter: SharePointSiteUrl."
    }
}

# Detect authentication mode
$clientIdProvided   = -not [string]::IsNullOrWhiteSpace($ClientId)
$thumbprintProvided = -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)

if ($clientIdProvided -xor $thumbprintProvided) {
    Write-Log -Message "Both -ClientId and -CertificateThumbprint must be provided together for non-interactive auth. Falling back to interactive login." -Level Warning
}

$useAppOnlyAuth = $clientIdProvided -and $thumbprintProvided

Write-Log -Message "Auth Mode  : $(if ($useAppOnlyAuth) { 'App-Only (Certificate)' } else { 'Interactive (Delegated)' })"

# Validate required modules
Assert-RequiredModule -ModuleName "Microsoft.Graph.Users"
Assert-RequiredModule -ModuleName "Microsoft.Graph.Groups"
Assert-RequiredModule -ModuleName "Microsoft.Graph.Identity.DirectoryManagement"
if (-not $SkipSharePointUpload) {
    Assert-RequiredModule -ModuleName "PnP.PowerShell"
}

#endregion

#region Connect to Microsoft Graph

Write-Log -Message "Connecting to Microsoft Graph..."

try {
    if ($useAppOnlyAuth) {
        Connect-MgGraph `
            -TenantId            $TenantId.ToString() `
            -ClientId            $ClientId `
            -CertificateThumbprint $CertificateThumbprint `
            -NoWelcome
    }
    else {
        Connect-MgGraph `
            -TenantId $TenantId.ToString() `
            -Scopes   "User.Read.All", "Group.Read.All", "OrgContact.Read.All" `
            -NoWelcome
    }
    Write-Log -Message "Connected to Microsoft Graph successfully."
}
catch {
    Write-Log -Message "Failed to connect to Microsoft Graph: $_" -Level Error
    throw
}

#endregion

#region Query Sync Errors

$allErrorRows  = [System.Collections.Generic.List[PSCustomObject]]::new()
$queryPartial  = $false

# ── Users ────────────────────────────────────────────────────────────────────
Write-Log -Message "Querying users with sync errors..."
try {
    Write-Progress -Activity "Entra Sync Error Report" -Status "Querying users..." -PercentComplete 10

    # Graph does not support onPremisesProvisioningErrors/any() as an indexed filter.
    # Supported approach: filter by onPremisesSyncEnabled eq true (server-side), then
    # filter locally for non-empty OnPremisesProvisioningErrors.
    $users = Get-MgUser `
        -Filter      "onPremisesSyncEnabled eq true" `
        -Property    "id,displayName,userPrincipalName,mail,onPremisesDistinguishedName,onPremisesImmutableId,onPremisesProvisioningErrors,accountEnabled,department,jobTitle" `
        -All `
        -ErrorAction Stop |
        Where-Object { @($_.OnPremisesProvisioningErrors).Count -gt 0 }

    Write-Log -Message "Users with sync errors: $(@($users).Count)"

    foreach ($user in $users) {
        ConvertTo-ErrorRows -ObjectType "User" -GraphObject $user | ForEach-Object { $allErrorRows.Add($_) }
    }
}
catch {
    Write-Log -Message "Could not retrieve user sync errors: $_" -Level Warning
    $queryPartial = $true
}

# ── Groups ───────────────────────────────────────────────────────────────────
Write-Log -Message "Querying groups with sync errors..."
try {
    Write-Progress -Activity "Entra Sync Error Report" -Status "Querying groups..." -PercentComplete 40

    $groups = Get-MgGroup `
        -Filter      "onPremisesSyncEnabled eq true" `
        -Property    "id,displayName,mail,onPremisesDistinguishedName,onPremisesProvisioningErrors" `
        -All `
        -ErrorAction Stop |
        Where-Object { @($_.OnPremisesProvisioningErrors).Count -gt 0 }

    Write-Log -Message "Groups with sync errors: $(@($groups).Count)"

    foreach ($group in $groups) {
        ConvertTo-ErrorRows -ObjectType "Group" -GraphObject $group | ForEach-Object { $allErrorRows.Add($_) }
    }
}
catch {
    Write-Log -Message "Could not retrieve group sync errors: $_" -Level Warning
    $queryPartial = $true
}

# ── Organizational Contacts ──────────────────────────────────────────────────
Write-Log -Message "Querying organizational contacts with sync errors..."
try {
    Write-Progress -Activity "Entra Sync Error Report" -Status "Querying contacts..." -PercentComplete 70

    $contacts = Get-MgContact `
        -Filter      "onPremisesSyncEnabled eq true" `
        -Property    "id,displayName,mail,onPremisesDistinguishedName,onPremisesProvisioningErrors" `
        -All `
        -ErrorAction Stop |
        Where-Object { @($_.OnPremisesProvisioningErrors).Count -gt 0 }

    Write-Log -Message "Contacts with sync errors: $(@($contacts).Count)"

    foreach ($contact in $contacts) {
        ConvertTo-ErrorRows -ObjectType "Contact" -GraphObject $contact | ForEach-Object { $allErrorRows.Add($_) }
    }
}
catch {
    Write-Log -Message "Could not retrieve contact sync errors: $_" -Level Warning
    $queryPartial = $true
}

Write-Progress -Activity "Entra Sync Error Report" -Completed
Write-Log -Message "Total sync error records collected: $($allErrorRows.Count)"

#endregion

#region Disconnect from Microsoft Graph

try {
    Disconnect-MgGraph | Out-Null
    Write-Log -Message "Disconnected from Microsoft Graph."
}
catch {
    Write-Log -Message "Could not cleanly disconnect from Microsoft Graph: $_" -Level Warning
}

#endregion

#region Export CSV

Write-Log -Message "Exporting CSV: $csvFile"

try {
    if ($allErrorRows.Count -gt 0) {
        $allErrorRows | Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force
    }
    else {
        # Write a headers-only CSV so the file is always present for downstream consumers.
        # Export-Csv with Select-Object -First 0 produces a zero-byte file in PowerShell 7;
        # writing the header line directly is the reliable alternative.
        '"ObjectType","ObjectId","DisplayName","UserPrincipalName","Mail","OnPremisesDistinguishedName","ErrorCategory","RawErrorCategory","OccurredDateTime","PropertyCausingError","ConflictingValue","AccountEnabled","Department","JobTitle","OnPremisesImmutableId"' |
            Set-Content -Path $csvFile -Encoding UTF8

        Write-Log -Message "No sync errors found. Empty CSV (headers only) written."
    }

    Write-Log -Message "CSV export complete. Records: $($allErrorRows.Count)"
}
catch {
    Write-Log -Message "Failed to export CSV: $_" -Level Error
    throw
}

#endregion

#region Upload to SharePoint Online

if (-not $SkipSharePointUpload) {
    Write-Log -Message "Connecting to SharePoint Online: $SharePointSiteUrl"

    try {
        # Override PnP.PowerShell's default 100-second HttpClient timeout.
        # SharePointPnPHttpTimeout (seconds) is read at connection time; -1 = infinite.
        # Ref: https://github.com/pnp/powershell/issues/4899
        $env:SharePointPnPHttpTimeout = 600  # 10 minutes
        Write-Log -Message "SharePoint HTTP timeout set to 600 s via SharePointPnPHttpTimeout."

        $pnpConnectParams = @{
            Url = $SharePointSiteUrl
        }
        if ($useAppOnlyAuth) {
            $pnpConnectParams['ClientId']   = $ClientId
            $pnpConnectParams['Thumbprint'] = $CertificateThumbprint
            $pnpConnectParams['Tenant']     = $TenantId.ToString()
        }
        else {
            $pnpConnectParams['Interactive'] = $true
        }
        Connect-PnPOnline @pnpConnectParams
        Write-Log -Message "Connected to SharePoint Online."
    }
    catch {
        Write-Log -Message "Failed to connect to SharePoint Online: $_" -Level Error
        throw
    }

    try {
        # Build folder hierarchy one level at a time via REST (avoids CSOM, which is
        # incompatible with Sites.Selected app-only auth).
        # Resolve the library root URL from SharePoint directly — avoids guessing the
        # server-relative URL, which may differ from the display/parameter name.
        $library     = Get-PnPList -Identity $SharePointDocumentLibrary -Includes RootFolder -ErrorAction Stop
        $currentPath = $library.RootFolder.ServerRelativeUrl.TrimEnd('/')
        Write-Log -Message "Library root: $currentPath"

        # Split base path into individual segments so multi-level paths (e.g. "Reports/Entra Sync Errors")
        # are created one folder at a time. Filter empty strings caused by leading/trailing slashes.
        $baseSegments   = $SharePointBaseFolderPath.Split('/') | Where-Object { -not [string]::IsNullOrWhiteSpace($_) }
        $folderSegments = @($baseSegments) + @($yearFolder, $monthFolder)

        foreach ($segment in $folderSegments) {
            try {
                Add-PnPFolder -Name $segment -Folder $currentPath -ErrorAction Stop | Out-Null
                Write-Log -Message "Created SharePoint folder: $currentPath/$segment"
            }
            catch {
                if ($_.Exception.Message -match "already exist|SPException") {
                    # Folder already exists — continue
                }
                else {
                    Write-Log -Message "Could not create folder '$segment' under '$currentPath': $_" -Level Warning
                }
            }
            $currentPath = "$currentPath/$segment"
        }

        Write-Log -Message "Target SharePoint folder: $currentPath"

        $csvFileName  = Split-Path -Path $csvFile -Leaf
        $maxAttempts  = 3
        $uploadDone   = $false

        for ($attempt = 1; $attempt -le $maxAttempts; $attempt++) {
            try {
                Write-Log -Message "Uploading '$csvFileName' to SharePoint (attempt $attempt / $maxAttempts)..."
                Add-PnPFile -Path $csvFile -Folder $currentPath -ErrorAction Stop | Out-Null
                Write-Log -Message "Upload successful. SharePoint path: $currentPath/$csvFileName"
                $uploadDone = $true
                break
            }
            catch {
                $isTimeout = ($_.Exception -is [System.Threading.Tasks.TaskCanceledException]) -or
                             ($_.Exception?.InnerException -is [System.TimeoutException]) -or
                             ($_.ToString() -match 'timeout|canceled|HttpClient|TaskCanceled')
                if ($isTimeout -and $attempt -lt $maxAttempts) {
                    Write-Log -Message "Upload timed out (attempt $attempt). Waiting 30s before retry..." -Level Warning
                    Start-Sleep -Seconds 30
                }
                else {
                    throw
                }
            }
        }

        if (-not $uploadDone) {
            throw "Upload failed after $maxAttempts attempts."
        }
    }
    catch {
        Write-Log -Message "Failed to upload file to SharePoint: $_" -Level Error
        throw
    }
    finally {
        try {
            Disconnect-PnPOnline
            Write-Log -Message "Disconnected from SharePoint Online."
        }
        catch {
            Write-Log -Message "Could not cleanly disconnect from SharePoint: $_" -Level Warning
        }
    }
}
else {
    Write-Log -Message "SharePoint upload skipped (-SkipSharePointUpload)."
}

#endregion

#region Summary

$duration = (Get-Date) - $scriptStartTime

Write-Log -Message "=== Script Completed ==="
Write-Log -Message "Duration           : $($duration.ToString('d\.hh\:mm\:ss'))"
Write-Log -Message "Total Error Records: $($allErrorRows.Count)"
if ($queryPartial) {
    Write-Log -Message "WARNING: One or more object type queries failed. The CSV may contain partial data." -Level Warning
}

if ($allErrorRows.Count -gt 0) {
    Write-Log -Message "--- By Category ---"
    $allErrorRows | Group-Object ErrorCategory | Sort-Object Name | ForEach-Object {
        Write-Log -Message "  $($_.Name): $($_.Count)"
    }

    Write-Log -Message "--- By Object Type ---"
    $allErrorRows | Group-Object ObjectType | Sort-Object Name | ForEach-Object {
        Write-Log -Message "  $($_.Name): $($_.Count)"
    }
}

Write-Log -Message "CSV File : $csvFile"
Write-Log -Message "Log File : $logFile"

#endregion
