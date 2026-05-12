#Requires -Version 7.0

<#
.SYNOPSIS
    Retrieves Entra Connect Sync errors and uploads a CSV report to SharePoint Online.

.DESCRIPTION
    Queries Microsoft Graph to collect Entra Connect (Azure AD Connect) synchronization
    errors for users, groups, and organizational contacts.

    Errors are grouped into three categories:
      - Duplicate Attribute    : PropertyConflict, AttributeValueMustBeUnique, etc.
      - Data Validation Failure: Validation, domain, or federation-related errors.
      - Other                  : All remaining error categories.

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
    Local directory for CSV and log output.
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
    Version: 1.0
    Date:    2026-05-11

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
        Sites.ReadWrite.All  OR  Sites.Selected (scoped to target site)

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

if (-not (Test-Path -Path $OutputPath -PathType Container)) {
    New-Item -Path $OutputPath -ItemType Directory -Force | Out-Null
}

$scriptStartTime = Get-Date
$datestamp        = $scriptStartTime.ToString("yyyyMMdd")
$timestamp        = $scriptStartTime.ToString("yyyyMMdd_HHmmss")
$yearFolder       = $scriptStartTime.ToString("yyyy")
$monthFolder      = $scriptStartTime.ToString("MMM")

$logFile = Join-Path -Path $OutputPath -ChildPath "Get-EntraSyncErrorUsers_$timestamp.log"
$csvFile = Join-Path -Path $OutputPath -ChildPath "EntraSyncErrors_$datestamp.csv"

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

    $duplicateAttributeCategories = @(
        "PropertyConflict",
        "MatchedWithSoftmatch",
        "AttributeValueMustBeUnique",
        "GeneratedUpnConflict"
    )

    $dataValidationCategories = @(
        "DataValidationFailed",
        "DataValidationFailure",
        "InvalidSoftMatch",
        "DomainMismatch",
        "DomainNotVerified",
        "FederatedDomainChange",
        "FederatedDomainChangeError",
        "InvalidFederatedUser",
        "ExchangeObjectConflict",
        "ExternalGovObjectDataValidationFailure"
    )

    if ($RawCategory -in $duplicateAttributeCategories) {
        return "Duplicate Attribute"
    }
    elseif ($RawCategory -in $dataValidationCategories) {
        return "Data Validation Failure"
    }
    else {
        return "Other"
    }
}

function Get-IdentityString {
    <#
    .SYNOPSIS
        Returns a non-empty identity string, preferring the first non-blank value.
    #>
    param ([string[]]$Candidates)

    foreach ($candidate in $Candidates) {
        if (-not [string]::IsNullOrWhiteSpace($candidate)) {
            return $candidate
        }
    }
    return ""
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
            UserPrincipalName           = if ($ObjectType -eq "User") { $GraphObject.UserPrincipalName } else { "" }
            Mail                        = $GraphObject.Mail
            OnPremisesDistinguishedName = $GraphObject.OnPremisesDistinguishedName
            ErrorCategory               = Get-SyncErrorCategory -RawCategory $provError.Category
            RawErrorCategory            = $provError.Category
            OccurredDateTime            = if ($provError.OccurredDateTime) {
                                              $provError.OccurredDateTime.ToString("yyyy-MM-dd HH:mm:ss")
                                          } else { "" }
            PropertyCausingError        = $provError.PropertyCausingError
            ConflictingValue            = $provError.Value
            AccountEnabled              = if ($ObjectType -eq "User") { $GraphObject.AccountEnabled } else { "" }
            Department                  = if ($ObjectType -eq "User") { $GraphObject.Department } else { "" }
            JobTitle                    = if ($ObjectType -eq "User") { $GraphObject.JobTitle } else { "" }
            OnPremisesImmutableId       = if ($ObjectType -eq "User") { $GraphObject.OnPremisesImmutableId } else { "" }
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
Write-Log -Message "Output Path: $OutputPath"

if (-not $SkipSharePointUpload) {
    if ([string]::IsNullOrWhiteSpace($SharePointSiteUrl)) {
        Write-Log -Message "-SharePointSiteUrl is required unless -SkipSharePointUpload is specified." -Level Error
        throw "Missing required parameter: SharePointSiteUrl."
    }
}

# Detect authentication mode
$useAppOnlyAuth = (
    -not [string]::IsNullOrWhiteSpace($ClientId) -and
    -not [string]::IsNullOrWhiteSpace($CertificateThumbprint)
)

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

$allErrorRows = [System.Collections.Generic.List[PSCustomObject]]::new()

# ── Users ────────────────────────────────────────────────────────────────────
Write-Log -Message "Querying users with sync errors..."
try {
    Write-Progress -Activity "Entra Sync Error Report" -Status "Querying users..." -PercentComplete 10

    $users = Get-MgUser `
        -Filter           "onPremisesProvisioningErrors/any()" `
        -Property         "id,displayName,userPrincipalName,mail,onPremisesDistinguishedName,onPremisesImmutableId,onPremisesProvisioningErrors,accountEnabled,department,jobTitle" `
        -All `
        -ConsistencyLevel "eventual" `
        -CountVariable    userErrorCount `
        -ErrorAction      Stop

    Write-Log -Message "Users with sync errors: $($users.Count)"

    foreach ($user in $users) {
        if ($user.OnPremisesProvisioningErrors.Count -gt 0) {
            $allErrorRows.AddRange((ConvertTo-ErrorRows -ObjectType "User" -GraphObject $user))
        }
    }
}
catch {
    Write-Log -Message "Could not retrieve user sync errors: $_" -Level Warning
}

# ── Groups ───────────────────────────────────────────────────────────────────
Write-Log -Message "Querying groups with sync errors..."
try {
    Write-Progress -Activity "Entra Sync Error Report" -Status "Querying groups..." -PercentComplete 40

    $groups = Get-MgGroup `
        -Filter           "onPremisesProvisioningErrors/any()" `
        -Property         "id,displayName,mail,onPremisesDistinguishedName,onPremisesProvisioningErrors" `
        -All `
        -ConsistencyLevel "eventual" `
        -CountVariable    groupErrorCount `
        -ErrorAction      Stop

    Write-Log -Message "Groups with sync errors: $($groups.Count)"

    foreach ($group in $groups) {
        if ($group.OnPremisesProvisioningErrors.Count -gt 0) {
            $allErrorRows.AddRange((ConvertTo-ErrorRows -ObjectType "Group" -GraphObject $group))
        }
    }
}
catch {
    Write-Log -Message "Could not retrieve group sync errors: $_" -Level Warning
}

# ── Organizational Contacts ──────────────────────────────────────────────────
Write-Log -Message "Querying organizational contacts with sync errors..."
try {
    Write-Progress -Activity "Entra Sync Error Report" -Status "Querying contacts..." -PercentComplete 70

    $contacts = Get-MgContact `
        -Filter           "onPremisesProvisioningErrors/any()" `
        -Property         "id,displayName,mail,onPremisesDistinguishedName,onPremisesProvisioningErrors" `
        -All `
        -ConsistencyLevel "eventual" `
        -CountVariable    contactErrorCount `
        -ErrorAction      Stop

    Write-Log -Message "Contacts with sync errors: $($contacts.Count)"

    foreach ($contact in $contacts) {
        if ($contact.OnPremisesProvisioningErrors.Count -gt 0) {
            $allErrorRows.AddRange((ConvertTo-ErrorRows -ObjectType "Contact" -GraphObject $contact))
        }
    }
}
catch {
    Write-Log -Message "Could not retrieve contact sync errors: $_" -Level Warning
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
        # Write an empty CSV with the correct headers so the file is always present
        [PSCustomObject]@{
            ObjectType                  = ""
            ObjectId                    = ""
            DisplayName                 = ""
            UserPrincipalName           = ""
            Mail                        = ""
            OnPremisesDistinguishedName = ""
            ErrorCategory               = ""
            RawErrorCategory            = ""
            OccurredDateTime            = ""
            PropertyCausingError        = ""
            ConflictingValue            = ""
            AccountEnabled              = ""
            Department                  = ""
            JobTitle                    = ""
            OnPremisesImmutableId       = ""
        } | Select-Object -First 0 |
            Export-Csv -Path $csvFile -NoTypeInformation -Encoding UTF8 -Force

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
        if ($useAppOnlyAuth) {
            Connect-PnPOnline `
                -Url       $SharePointSiteUrl `
                -ClientId  $ClientId `
                -Thumbprint $CertificateThumbprint `
                -Tenant    $TenantId.ToString()
        }
        else {
            Connect-PnPOnline -Url $SharePointSiteUrl -Interactive
        }
        Write-Log -Message "Connected to SharePoint Online."
    }
    catch {
        Write-Log -Message "Failed to connect to SharePoint Online: $_" -Level Error
        throw
    }

    try {
        # Build folder path: {Library}/{BasePath}/{YYYY}/{MMM}
        $sharePointFolderPath = "$SharePointDocumentLibrary/$SharePointBaseFolderPath/$yearFolder/$monthFolder"
        Write-Log -Message "Ensuring SharePoint folder exists: $sharePointFolderPath"

        # Resolve-PnPFolder creates the full folder hierarchy if it doesn't exist
        $targetFolder = Resolve-PnPFolder -SiteRelativePath $sharePointFolderPath

        $csvFileName = Split-Path -Path $csvFile -Leaf
        Write-Log -Message "Uploading '$csvFileName' to SharePoint..."

        Add-PnPFile -Path $csvFile -Folder $targetFolder.ServerRelativeUrl | Out-Null

        Write-Log -Message "Upload successful. SharePoint path: $sharePointFolderPath/$csvFileName"
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
Write-Log -Message "Duration           : $($duration.ToString('hh\:mm\:ss'))"
Write-Log -Message "Total Error Records: $($allErrorRows.Count)"

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
