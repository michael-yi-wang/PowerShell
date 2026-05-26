#Requires -Version 7.0

<#
.SYNOPSIS
    Inspects and modifies Owner and Site Collection Admin permissions on a OneDrive for Business site.

.DESCRIPTION
    Connects to a OneDrive for Business (personal site) using PnP.PowerShell with
    certificate-based app-only authentication. Provides an interactive menu with two
    phases of operation:

    Phase 1 — Inspection (OneDrive URL only):
        Once a OneDrive URL is provided, the script can connect and display the current
        primary owner and all site collection admins without requiring a user UPN.

    Phase 2 — Permission Grant (OneDrive URL + User UPN):
        When a User UPN is also supplied, additional options become available to grant
        Owner, Site Collection Admin, or both permissions to that user.

    Supports both active OneDrive profiles and profiles of deleted users that are
    retained by a retention policy ("Profile Missing" state in the SharePoint Admin
    Centre). Existing site collection admins are preserved when adding a new one.

.PARAMETER AppId
    The Application (Client) ID of the Entra ID app registration.
    Used with the 'Individual' parameter set.

.PARAMETER Thumbprint
    The SHA1 certificate thumbprint used for app-only authentication.
    On Windows the certificate must be in the CurrentUser\My store.
    On macOS the certificate must be imported into the login Keychain.
    Used with the 'Individual' parameter set.

.PARAMETER TenantId
    The Entra ID tenant ID (GUID) or primary domain (e.g. contoso.onmicrosoft.com).
    Used with the 'Individual' parameter set.

.PARAMETER ConfigFile
    Path to a JSON file containing AppId, Thumbprint, and TenantId.
    Used with the 'ConfigFile' parameter set.

    Expected format:
    {
        "AppId"      : "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
        "Thumbprint" : "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
        "TenantId"   : "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
    }

.EXAMPLE
    .\Change-OneDrivePermission.ps1 -AppId "00000000-0000-0000-0000-000000000000" `
                                    -Thumbprint "ABC123DEF456..." `
                                    -TenantId "contoso.onmicrosoft.com"

.EXAMPLE
    .\Change-OneDrivePermission.ps1 -ConfigFile ".\config.json"

.NOTES
    Author   : Michael Wang
    Version  : 1.10.0
    Requires : PowerShell 7.0+, PnP.PowerShell module

    At startup the script verifies that PowerShell 7.0 or later is running and
    that PnP.PowerShell is installed. If the module is absent the script offers
    to install it automatically (CurrentUser scope) before continuing.

    The Entra ID app registration must hold the SharePoint application permission:
        Sites.FullControl.All  (admin consent required)
#>

[CmdletBinding(DefaultParameterSetName = 'Individual')]
param (
    [Parameter(Mandatory, ParameterSetName = 'Individual',
        HelpMessage = 'Entra ID Application (Client) ID')]
    [ValidateNotNullOrEmpty()]
    [string]$AppId,

    [Parameter(Mandatory, ParameterSetName = 'Individual',
        HelpMessage = 'Certificate thumbprint for app-only authentication')]
    [ValidateNotNullOrEmpty()]
    [string]$Thumbprint,

    [Parameter(Mandatory, ParameterSetName = 'Individual',
        HelpMessage = 'Entra ID Tenant ID or primary domain')]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory, ParameterSetName = 'ConfigFile',
        HelpMessage = 'Path to JSON configuration file')]
    [ValidateScript({ Test-Path $_ -PathType Leaf })]
    [string]$ConfigFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Initialisation

$script:LogDir  = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
$script:LogFile = Join-Path -Path $script:LogDir -ChildPath "Change-OneDrivePermission_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

if (-not (Test-Path -Path $script:LogDir -PathType Container)) {
    New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
}

#endregion

#region Logging

function Write-Log {
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry     = "[$timestamp] [$($Level.ToUpper().PadRight(7))] $Message"

    Add-Content -Path $script:LogFile -Value $entry -Encoding UTF8

    $color = switch ($Level) {
        'Info'    { 'Green'  }
        'Warning' { 'Yellow' }
        'Error'   { 'Red'    }
    }
    Write-Host $entry -ForegroundColor $color
}

#endregion

#region Module Check

function Assert-PowerShellVersion {
    $required = [Version]'7.0'
    $current  = $PSVersionTable.PSVersion

    if ($current -lt $required) {
        Write-Host ''
        Write-Host "  [ERROR] This script requires PowerShell $required or later." -ForegroundColor Red
        Write-Host "          Detected version: $current" -ForegroundColor Yellow
        Write-Host ''
        Write-Host '  Download PowerShell 7 from: https://aka.ms/powershell' -ForegroundColor Cyan
        Write-Host ''
        exit 1
    }

    Write-Log -Message "PowerShell version: $current (OK)"
}

function Assert-PnPModule {
    if (-not (Get-Module -ListAvailable -Name 'PnP.PowerShell')) {
        Write-Host ''
        Write-Host '  [WARNING] PnP.PowerShell module is not installed.' -ForegroundColor Yellow
        Write-Host ''

        $install = (Read-Host '  Install PnP.PowerShell now for the current user? (Y/N)').Trim().ToUpper()

        if ($install -ne 'Y') {
            Write-Host ''
            Write-Host '  Installation declined. Script cannot continue.' -ForegroundColor Red
            Write-Host '  To install manually, run:' -ForegroundColor Yellow
            Write-Host '    Install-Module -Name PnP.PowerShell -Scope CurrentUser' -ForegroundColor Cyan
            Write-Host ''
            exit 1
        }

        try {
            Write-Log -Message 'Installing PnP.PowerShell module (CurrentUser scope)...'
            Install-Module -Name 'PnP.PowerShell' -Scope CurrentUser -ErrorAction Stop
            Write-Log -Message 'PnP.PowerShell installed successfully.'
        }
        catch {
            Write-Log -Message "Module installation failed: $($_.Exception.Message)" -Level Error
            exit 1
        }
    }
    Import-Module -Name 'PnP.PowerShell' -ErrorAction Stop
    Write-Log -Message 'PnP.PowerShell module loaded.'
}

#endregion

#region Helpers

function Test-OneDriveUrl {
    # Accepts only OneDrive personal site collection root URLs.
    param ([string]$Url)
    $trimmed = $Url.TrimEnd('/')
    return $trimmed -match '^https://[a-zA-Z0-9][a-zA-Z0-9-]*-my\.sharepoint\.com/personal/[^/]+$'
}

function Get-AdminCenterUrl {
    # Derives the SPO admin centre URL from a OneDrive personal site URL.
    # e.g. https://contoso-my.sharepoint.com/personal/... → https://contoso-admin.sharepoint.com
    [OutputType([string])]
    param ([string]$OneDriveUrl)

    if ($OneDriveUrl -match '^(https://[a-zA-Z0-9][a-zA-Z0-9-]*)-my\.sharepoint\.com') {
        return "$($Matches[1])-admin.sharepoint.com"
    }
    return $null
}

function Resolve-AppConfig {
    # Returns a hashtable with AppId, Thumbprint, and TenantId.
    [OutputType([hashtable])]
    param ()

    if ($PSCmdlet.ParameterSetName -eq 'ConfigFile') {
        try {
            Write-Log -Message "Loading configuration from: $ConfigFile"
            $json = Get-Content -Path $ConfigFile -Raw -Encoding UTF8 |
                    ConvertFrom-Json -ErrorAction Stop

            foreach ($key in @('AppId', 'Thumbprint', 'TenantId')) {
                if ([string]::IsNullOrWhiteSpace($json.$key)) {
                    throw "Required field '$key' is missing or empty in the config file."
                }
            }

            return @{
                AppId      = $json.AppId
                Thumbprint = $json.Thumbprint
                TenantId   = $json.TenantId
            }
        }
        catch {
            Write-Log -Message "Failed to load config file: $($_.Exception.Message)" -Level Error
            exit 1
        }
    }
    else {
        return @{
            AppId      = $AppId
            Thumbprint = $Thumbprint
            TenantId   = $TenantId
        }
    }
}

#endregion

#region SPO Operations

function Connect-ToOneDriveSite {
    [OutputType([bool])]
    param (
        [string]$SiteUrl,
        [hashtable]$Config
    )

    try {
        Write-Log -Message "Connecting to: $SiteUrl"
        Connect-PnPOnline -Url        $SiteUrl `
                          -ClientId   $Config.AppId `
                          -Thumbprint $Config.Thumbprint `
                          -Tenant     $Config.TenantId `
                          -ErrorAction Stop
        Write-Log -Message 'Connection established.'
        return $true
    }
    catch {
        Write-Log -Message "Connection failed for '$SiteUrl': $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Connect-ToAdminCenter {
    [OutputType([bool])]
    param (
        [string]$AdminUrl,
        [hashtable]$Config
    )

    try {
        Write-Log -Message "Connecting to admin centre: $AdminUrl"
        Connect-PnPOnline -Url        $AdminUrl `
                          -ClientId   $Config.AppId `
                          -Thumbprint $Config.Thumbprint `
                          -Tenant     $Config.TenantId `
                          -ErrorAction Stop
        Write-Log -Message 'Admin centre connection established.'
        return $true
    }
    catch {
        Write-Log -Message "Admin centre connection failed: $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Get-CurrentSiteAdmins {
    # Returns existing site collection admin objects, or an empty array on failure.
    [OutputType([object[]])]
    param ()

    try {
        $admins = Get-PnPSiteCollectionAdmin -ErrorAction Stop
        return @($admins)
    }
    catch {
        Write-Log -Message "Unable to retrieve site collection admins: $($_.Exception.Message)" -Level Warning
        return @()
    }
}


function Grant-OneDriveOwner {
    # Sets the primary owner via the admin centre. Replaces any existing owner.
    # Requires an active admin centre connection (Connect-ToAdminCenter).
    # Verifies the change was applied — Set-PnPTenantSite -Owner can silently no-op
    # for OneDrive sites in 'Profile Missing' state (departed user, retention hold).
    [OutputType([bool])]
    param (
        [string]$UserUPN,
        [string]$SiteUrl
    )

    try {
        Write-Log -Message "Setting '$UserUPN' as owner of '$SiteUrl'."
        Set-PnPTenantSite -Url $SiteUrl -Owner $UserUPN -ErrorAction Stop

        # Verify the change was actually applied — the API can return success without
        # persisting the change for sites in Profile Missing state.
        $updated   = Get-PnPTenantSite -Url $SiteUrl -ErrorAction Stop
        $newOwner  = if     ($updated.Owner -match '\|([^|]+)$') { $Matches[1] }
                     elseif ($updated.Owner -match '@')          { $updated.Owner }
                     else                                        { $updated.Owner }

        if (-not [string]::IsNullOrEmpty($newOwner) -and $newOwner.ToLower() -ne $UserUPN.ToLower()) {
            Write-Log -Message "Owner change was accepted but did not apply — current owner is still '$($updated.OwnerName)'. Site may be in 'Profile Missing' state." -Level Warning
            Write-Host ''
            Write-Host '  WARNING: SharePoint accepted the request but the owner was not changed.' -ForegroundColor Yellow
            Write-Host "  Current primary owner remains: $($updated.OwnerName)" -ForegroundColor Yellow
            Write-Host ''
            Write-Host '  This occurs for OneDrive sites in ''Profile Missing'' state (departed user).' -ForegroundColor Yellow
            Write-Host '  Change the primary owner manually in the SharePoint Admin Centre:' -ForegroundColor Yellow
            Write-Host '    Active sites → select site → Membership tab → Primary admin' -ForegroundColor DarkGray
            return $false
        }

        Write-Log -Message 'Owner updated and verified successfully.'
        return $true
    }
    catch {
        $msg = $_.Exception.Message
        Write-Log -Message "Failed to set owner '$UserUPN': $msg" -Level Error

        if ($msg -match 'Forbidden') {
            Write-Host ''
            Write-Host '  Possible causes for the Forbidden error:' -ForegroundColor Yellow
            Write-Host '    1. The UPN is a deleted/departed account — SharePoint cannot assign a' -ForegroundColor Yellow
            Write-Host '       deleted user as primary owner. Use an active admin UPN instead.' -ForegroundColor Yellow
            Write-Host '    2. The Entra ID app registration does not hold the SharePoint' -ForegroundColor Yellow
            Write-Host '       Administrator role. Assign it in Entra ID → Enterprise Applications.' -ForegroundColor Yellow
            Write-Host '  For departed-user OneDrive sites, use Site Collection Admin (option 2)' -ForegroundColor Yellow
            Write-Host '  to grant access without changing primary ownership.' -ForegroundColor Yellow
        }

        return $false
    }
}

function Grant-OneDriveSiteAdmin {
    # Adds the user as a site collection admin via the admin centre. Existing admins are preserved.
    # Requires an active admin centre connection (Connect-ToAdminCenter).
    [OutputType([bool])]
    param (
        [string]$UserUPN,
        [string]$SiteUrl
    )

    try {
        Write-Log -Message "Adding '$UserUPN' as site collection admin of '$SiteUrl'."
        Set-PnPTenantSite -Url $SiteUrl -Owners @($UserUPN) -ErrorAction Stop
        Write-Log -Message 'Site collection admin added successfully.'
        return $true
    }
    catch {
        $msg = $_.Exception.Message
        Write-Log -Message "Failed to add site collection admin '$UserUPN': $msg" -Level Error

        if ($msg -match 'Forbidden') {
            Write-Host ''
            Write-Host '  Possible causes for the Forbidden error:' -ForegroundColor Yellow
            Write-Host '    1. The OneDrive site is still locked (ReadOnly/NoAccess) after account restore.' -ForegroundColor Yellow
            Write-Host '    2. The Entra ID app lacks the SharePoint Administrator role in Entra ID.' -ForegroundColor Yellow
        }

        return $false
    }
}

#endregion

#region Site Info Check

function Show-OneDriveSiteInfo {
    param (
        [string]   $OneDriveUrl,
        [hashtable]$Config
    )

    Write-Log -Message "Checking site info for: $OneDriveUrl"

    # Phase 1: connect to the OneDrive site to read owner and admins
    $connected = Connect-ToOneDriveSite -SiteUrl $OneDriveUrl -Config $Config
    if (-not $connected) {
        Write-Host ''
        Write-Host '  Unable to connect to the OneDrive site. Check the log for details.' -ForegroundColor Red
        Read-Host "`n  Press Enter to return to the menu"
        return
    }

    $admins = @()
    try {
        $admins = @(Get-CurrentSiteAdmins)
    }
    finally {
        try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
    }

    # Phase 2: connect to the admin centre to read site status and primary owner.
    # Primary owner must come from Get-PnPTenantSite — Get-PnPSite.Owner does not
    # reflect changes made via Set-PnPTenantSite -Owner.
    $lockState     = $null
    $archiveStatus = $null
    $ownerName     = $null
    $ownerEmail    = $null

    $adminUrl = Get-AdminCenterUrl -OneDriveUrl $OneDriveUrl
    if ($adminUrl) {
        $adminConnected = Connect-ToAdminCenter -AdminUrl $adminUrl -Config $Config
        if ($adminConnected) {
            try {
                $tenantSite    = Get-PnPTenantSite -Url $OneDriveUrl -ErrorAction Stop
                $lockState     = $tenantSite.LockState.ToString()
                $archiveStatus = $tenantSite.ArchiveStatus.ToString()
                $ownerName = $tenantSite.OwnerName
                # Owner may be a claims login (i:0#.f|membership|email) or a plain UPN
                if     ($tenantSite.Owner -match '\|([^|]+)$') { $ownerEmail = $Matches[1] }
                elseif ($tenantSite.Owner -match '@')          { $ownerEmail = $tenantSite.Owner }
            }
            catch {
                Write-Log -Message "Unable to retrieve tenant site status: $($_.Exception.Message)" -Level Warning
            }
            finally {
                try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
            }
        }
    }

    Write-Host ''
    Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '  |  Site Information                                |' -ForegroundColor Cyan
    Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
    Write-Host "  |  OneDrive : $OneDriveUrl" -ForegroundColor White
    Write-Host '  |' -ForegroundColor Cyan
    Write-Host '  |  Site Status:' -ForegroundColor Cyan

    $lockColor = switch ($lockState) {
        'Unlock'   { 'Green'  }
        'ReadOnly' { 'Yellow' }
        'NoAccess' { 'Red'    }
        default    { 'DarkGray' }
    }
    Write-Host '  |    Lock State     : ' -NoNewline -ForegroundColor Cyan
    if ($null -ne $lockState) {
        Write-Host $lockState -ForegroundColor $lockColor
    }
    else {
        Write-Host '(unable to retrieve)' -ForegroundColor DarkGray
    }

    $archiveColor = switch ($archiveStatus) {
        'NotArchived'   { 'Green'  }
        'FullyArchived' { 'Red'    }
        'Archived'      { 'Yellow' }
        'Reactivating'  { 'Yellow' }
        default         { 'White'  }
    }
    Write-Host '  |    Archive Status : ' -NoNewline -ForegroundColor Cyan
    if ($null -ne $archiveStatus) {
        Write-Host $archiveStatus -ForegroundColor $archiveColor
    }
    else {
        Write-Host '(unable to retrieve)' -ForegroundColor DarkGray
    }

    Write-Host '  |' -ForegroundColor Cyan
    Write-Host '  |  Primary Owner:' -ForegroundColor Cyan

    if (-not [string]::IsNullOrEmpty($ownerName)) {
        $ownerDisplay = if (-not [string]::IsNullOrEmpty($ownerEmail)) {
            "$ownerName ($ownerEmail)"
        }
        else {
            $ownerName
        }
        Write-Host "  |    $ownerDisplay" -ForegroundColor White
    }
    else {
        Write-Host '  |    (unable to retrieve)' -ForegroundColor DarkGray
    }

    Write-Host '  |' -ForegroundColor Cyan
    Write-Host '  |  Site Collection Admins:' -ForegroundColor Cyan

    if ($admins.Count -gt 0) {
        foreach ($admin in $admins) {
            $display = if (-not [string]::IsNullOrEmpty($admin.Email)) {
                "$($admin.Title) ($($admin.Email))"
            }
            else {
                $admin.LoginName
            }
            Write-Host "  |    - $display" -ForegroundColor White
        }
    }
    else {
        Write-Host '  |    (none found)' -ForegroundColor DarkGray
    }

    Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan

    Read-Host "`n  Press Enter to return to the menu"
}

function Invoke-SiteUnlockIfNeeded {
    # Checks the OneDrive site lock state from an active admin centre connection and
    # unlocks the site if it is in ReadOnly or NoAccess state.
    # When a user account is deleted, SharePoint locks the OneDrive; re-enabling the
    # account does not automatically unlock it — write operations fail with Forbidden
    # until the site is explicitly set back to Unlock.
    [OutputType([bool])]
    param ([string]$SiteUrl)

    try {
        $site      = Get-PnPTenantSite -Url $SiteUrl -ErrorAction Stop
        $lockState = $site.LockState.ToString()
        Write-Log -Message "Site lock state: $lockState"

        if ($lockState -eq 'Unlock') {
            return $true
        }

        Write-Log -Message "Site is locked ($lockState) — attempting to unlock." -Level Warning
        Set-PnPTenantSite -Url $SiteUrl -LockState Unlock -ErrorAction Stop
        Write-Log -Message 'Site unlocked successfully.'
        return $true
    }
    catch {
        Write-Log -Message "Unable to verify/unlock site state: $($_.Exception.Message)" -Level Warning
        Write-Host ''
        Write-Host '  Warning: Could not verify site lock state. If the grant fails with Forbidden:' -ForegroundColor Yellow
        Write-Host '    1. The OneDrive may still be locked (ReadOnly/NoAccess) after account restore.' -ForegroundColor Yellow
        Write-Host '       Unlock it manually: SharePoint Admin Centre → Active Sites → select site → Policies.' -ForegroundColor Yellow
        Write-Host '    2. The Entra ID app may lack the SharePoint Administrator role.' -ForegroundColor Yellow
        Write-Host '       Assign it in Entra ID → Enterprise Applications → [app] → Roles and administrators.' -ForegroundColor Yellow
        return $false
    }
}

#endregion

#region Permission Grant Workflow

function Invoke-GrantPermission {
    param (
        [string]   $OneDriveUrl,
        [string]   $UserUPN,
        [string]   $PermissionType,    # 'Owner' | 'Admin' | 'Both'
        [hashtable]$Config
    )

    Write-Log -Message "Starting permission grant — UPN: '$UserUPN', URL: '$OneDriveUrl', Type: '$PermissionType'."

    #--- Phase 1: connect to the OneDrive site to read current state ---
    $connected = Connect-ToOneDriveSite -SiteUrl $OneDriveUrl -Config $Config
    if (-not $connected) {
        Write-Host ''
        Write-Host '  Unable to connect to the OneDrive site. Check the log for details.' -ForegroundColor Red
        Read-Host "`n  Press Enter to return to the menu"
        return
    }

    try {
        $existingAdmins = @(Get-CurrentSiteAdmins)
        Write-Host ''
        Write-Host '  Current Site Collection Admins:' -ForegroundColor Cyan
        if ($existingAdmins.Count -gt 0) {
            foreach ($admin in $existingAdmins) {
                $display = if (-not [string]::IsNullOrEmpty($admin.Email)) {
                    "$($admin.Title) ($($admin.Email))"
                }
                else {
                    $admin.LoginName
                }
                Write-Host "    - $display" -ForegroundColor White
            }
        }
        else {
            Write-Host '    (none found)' -ForegroundColor DarkGray
        }
    }
    finally {
        try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
    }

    # Summarise pending action and ask for confirmation before connecting to admin centre
    Write-Host ''
    Write-Host '  Pending Action:' -ForegroundColor Cyan
    Write-Host "    OneDrive   : $OneDriveUrl" -ForegroundColor White
    Write-Host "    User       : $UserUPN" -ForegroundColor White
    Write-Host "    Permission : $PermissionType" -ForegroundColor White
    Write-Host ''

    if ($PermissionType -in @('Owner', 'Both')) {
        Write-Host '  NOTE: Setting a new owner will replace the current primary owner.' -ForegroundColor Yellow
    }

    $confirm = Read-Host '  Proceed? (Y/N)'
    if ($confirm.Trim().ToUpper() -ne 'Y') {
        Write-Log -Message 'Permission grant cancelled by operator.' -Level Warning
        Write-Host "`n  Operation cancelled." -ForegroundColor Yellow
        Read-Host "`n  Press Enter to return to the menu"
        return
    }

    #--- Phase 2: connect to the admin centre to perform grant operations ---
    $adminUrl = Get-AdminCenterUrl -OneDriveUrl $OneDriveUrl
    if (-not $adminUrl) {
        Write-Log -Message "Could not derive admin centre URL from: $OneDriveUrl" -Level Error
        Write-Host '  Unable to determine the SharePoint admin centre URL.' -ForegroundColor Red
        Read-Host "`n  Press Enter to return to the menu"
        return
    }

    $adminConnected = Connect-ToAdminCenter -AdminUrl $adminUrl -Config $Config
    if (-not $adminConnected) {
        Write-Host ''
        Write-Host '  Unable to connect to the SharePoint admin centre. Check the log for details.' -ForegroundColor Red
        Read-Host "`n  Press Enter to return to the menu"
        return
    }

    try {
        # Archived sites return Forbidden on all read/write operations — block early.
        $tenantSite    = Get-PnPTenantSite -Url $OneDriveUrl -ErrorAction Stop
        $archiveStatus = $tenantSite.ArchiveStatus.ToString()
        if ($archiveStatus -eq 'FullyArchived') {
            Write-Log -Message "Site is fully archived — permission grant blocked." -Level Error
            Write-Host ''
            Write-Host '  ERROR: This OneDrive site is fully archived.' -ForegroundColor Red
            Write-Host '  Archived sites reject all permission changes.' -ForegroundColor Yellow
            Write-Host ''
            Write-Host '  Reactivate the site first, then retry:' -ForegroundColor Yellow
            Write-Host '    SharePoint Admin Centre → Sites → Archived sites' -ForegroundColor DarkGray
            Write-Host '    → select site → Reactivate' -ForegroundColor DarkGray
            Read-Host "`n  Press Enter to return to the menu"
            return
        }

        # Unlock the site if it was locked when the user account was deleted.
        # Re-enabling the account does not automatically restore the Unlock state.
        Invoke-SiteUnlockIfNeeded -SiteUrl $OneDriveUrl | Out-Null

        $ownerSuccess = $true
        $adminSuccess = $true
        $ownerError   = [string]::Empty
        $adminError   = [string]::Empty

        switch ($PermissionType) {
            'Owner' {
                $ownerSuccess = Grant-OneDriveOwner -UserUPN $UserUPN -SiteUrl $OneDriveUrl
                if (-not $ownerSuccess) { $ownerError = 'See log for details.' }
            }
            'Admin' {
                $adminSuccess = Grant-OneDriveSiteAdmin -UserUPN $UserUPN -SiteUrl $OneDriveUrl
                if (-not $adminSuccess) { $adminError = 'See log for details.' }
            }
            'Both' {
                # Grant site collection admin first so the user has access, then set as owner
                $adminSuccess = Grant-OneDriveSiteAdmin -UserUPN $UserUPN -SiteUrl $OneDriveUrl
                if (-not $adminSuccess) { $adminError = 'See log for details.' }

                $ownerSuccess = Grant-OneDriveOwner -UserUPN $UserUPN -SiteUrl $OneDriveUrl
                if (-not $ownerSuccess) { $ownerError = 'See log for details.' }
            }
        }

        # Display result summary
        Write-Host ''
        Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
        Write-Host '  |  Result Summary                                  |' -ForegroundColor Cyan
        Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
        Write-Host "  |  OneDrive : $OneDriveUrl"
        Write-Host "  |  User     : $UserUPN"
        Write-Host '  |'

        if ($PermissionType -in @('Owner', 'Both')) {
            $ownerLabel = if ($ownerSuccess) { 'SUCCESS' } else { "FAILED  — $ownerError" }
            $ownerColor = if ($ownerSuccess) { 'Green' } else { 'Red' }
            Write-Host '  |  Owner               : ' -NoNewline
            Write-Host $ownerLabel -ForegroundColor $ownerColor
        }

        if ($PermissionType -in @('Admin', 'Both')) {
            $adminLabel = if ($adminSuccess) { 'SUCCESS' } else { "FAILED  — $adminError" }
            $adminColor = if ($adminSuccess) { 'Green' } else { 'Red' }
            Write-Host '  |  Site Collection Admin: ' -NoNewline
            Write-Host $adminLabel -ForegroundColor $adminColor
        }

        Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
    }
    finally {
        try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
    }

    Read-Host "`n  Press Enter to return to the menu"
}

function Invoke-RemoveSiteAdmin {
    param (
        [string]   $OneDriveUrl,
        [hashtable]$Config
    )

    Write-Log -Message "Starting remove site collection admin — URL: '$OneDriveUrl'."

    # Fetch primary owner from admin centre first — Get-PnPSite.Owner does not reflect
    # changes made via Set-PnPTenantSite -Owner, so the admin centre is the source of truth.
    $primaryOwnerEmail = $null
    $adminUrl = Get-AdminCenterUrl -OneDriveUrl $OneDriveUrl
    if ($adminUrl) {
        $adminConnected = Connect-ToAdminCenter -AdminUrl $adminUrl -Config $Config
        if ($adminConnected) {
            try {
                $tenantSite = Get-PnPTenantSite -Url $OneDriveUrl -ErrorAction Stop
                if     ($tenantSite.Owner -match '\|([^|]+)$') { $primaryOwnerEmail = $Matches[1].ToLower() }
                elseif ($tenantSite.Owner -match '@')          { $primaryOwnerEmail = $tenantSite.Owner.ToLower() }
            }
            catch {
                Write-Log -Message "Unable to retrieve primary owner from admin centre: $($_.Exception.Message)" -Level Warning
            }
            finally {
                try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
            }
        }
    }

    $connected = Connect-ToOneDriveSite -SiteUrl $OneDriveUrl -Config $Config
    if (-not $connected) {
        Write-Host ''
        Write-Host '  Unable to connect to the OneDrive site. Check the log for details.' -ForegroundColor Red
        Read-Host "`n  Press Enter to return to the menu"
        return
    }

    try {
        $admins = @(Get-CurrentSiteAdmins)

        $removable = @($admins | Where-Object {
            $e = if (-not [string]::IsNullOrEmpty($_.Email)) { $_.Email.ToLower() } else { $null }
            -not ($primaryOwnerEmail -and $e -and ($e -eq $primaryOwnerEmail))
        })

        if ($removable.Count -eq 0) {
            Write-Host ''
            Write-Host '  No removable site collection admins found.' -ForegroundColor Yellow
            Write-Host '  (The primary owner is excluded from this list.)' -ForegroundColor DarkGray
            Read-Host "`n  Press Enter to return to the menu"
            return
        }

        # Numbered list
        Write-Host ''
        Write-Host '  Site Collection Admins  (primary owner excluded):' -ForegroundColor Cyan
        Write-Host ''
        for ($i = 0; $i -lt $removable.Count; $i++) {
            $a = $removable[$i]
            $d = if (-not [string]::IsNullOrEmpty($a.Email)) { "$($a.Title) ($($a.Email))" } else { $a.LoginName }
            Write-Host "    [$($i + 1)]  $d" -ForegroundColor White
        }
        Write-Host ''
        Write-Host '    [A]  All of the above' -ForegroundColor White
        Write-Host '    [B]  Back' -ForegroundColor White
        Write-Host ''

        $raw = (Read-Host '  Enter selection (e.g. 1  or  1,3  or  A)').Trim().ToUpper()

        if ($raw -eq 'B') { return }

        $toRemove = @()
        if ($raw -eq 'A') {
            $toRemove = $removable
        }
        else {
            # Deduplicate via index set
            $seen = [System.Collections.Generic.HashSet[int]]::new()
            foreach ($token in ($raw -split ',')) {
                $t = $token.Trim()
                if ($t -match '^\d+$') {
                    $n = [int]$t
                    if ($n -ge 1 -and $n -le $removable.Count) {
                        if ($seen.Add($n - 1)) {
                            $toRemove += $removable[$n - 1]
                        }
                    }
                    else {
                        Write-Host "  '$t' is out of range — ignored." -ForegroundColor Yellow
                    }
                }
                else {
                    Write-Host "  '$t' is not a valid number — ignored." -ForegroundColor Yellow
                }
            }
        }

        if ($toRemove.Count -eq 0) {
            Write-Host '  No valid admins selected.' -ForegroundColor Yellow
            Read-Host "`n  Press Enter to return to the menu"
            return
        }

        # Confirmation
        Write-Host ''
        Write-Host '  The following will be removed as site collection admins:' -ForegroundColor Cyan
        foreach ($a in $toRemove) {
            $d = if (-not [string]::IsNullOrEmpty($a.Email)) { "$($a.Title) ($($a.Email))" } else { $a.LoginName }
            Write-Host "    - $d" -ForegroundColor White
        }
        Write-Host ''

        $confirm = Read-Host '  Proceed? (Y/N)'
        if ($confirm.Trim().ToUpper() -ne 'Y') {
            Write-Log -Message 'Remove site collection admin cancelled by operator.' -Level Warning
            Write-Host "`n  Operation cancelled." -ForegroundColor Yellow
            Read-Host "`n  Press Enter to return to the menu"
            return
        }

        # Perform removal
        $results = [ordered]@{}
        foreach ($a in $toRemove) {
            $identity = if (-not [string]::IsNullOrEmpty($a.Email)) { $a.Email } else { $a.LoginName }
            $display  = if (-not [string]::IsNullOrEmpty($a.Email)) { "$($a.Title) ($($a.Email))" } else { $a.LoginName }
            try {
                Remove-PnPSiteCollectionAdmin -Owners @($identity) -ErrorAction Stop
                Write-Log -Message "Removed site collection admin: '$display'."
                $results[$display] = $true
            }
            catch {
                Write-Log -Message "Failed to remove '$display': $($_.Exception.Message)" -Level Error
                $results[$display] = $false
            }
        }

        # Result summary
        Write-Host ''
        Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
        Write-Host '  |  Result Summary                                  |' -ForegroundColor Cyan
        Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
        foreach ($key in $results.Keys) {
            $label = if ($results[$key]) { 'REMOVED' } else { 'FAILED ' }
            $color = if ($results[$key]) { 'Green'  } else { 'Red'   }
            Write-Host "  |  $key" -ForegroundColor White
            Write-Host '  |    Status : ' -NoNewline -ForegroundColor Cyan
            Write-Host $label -ForegroundColor $color
            Write-Host '  |' -ForegroundColor Cyan
        }
        Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
    }
    finally {
        try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
    }

    Read-Host "`n  Press Enter to return to the menu"
}

#endregion

#region Permission Sub-Menu

function Show-PermissionSubMenu {
    param (
        [string]   $OneDriveUrl,
        [string]   $UserUPN,
        [hashtable]$Config
    )

    Clear-Host
    Write-Host ''
    Write-Host '  +================================================+' -ForegroundColor Cyan
    Write-Host '  |   Select Permission Type                       |' -ForegroundColor Cyan
    Write-Host '  +================================================+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host "    OneDrive : $OneDriveUrl" -ForegroundColor Yellow
    Write-Host "    User     : $UserUPN" -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '    [1]  Owner only             (replaces current owner)' -ForegroundColor White
    Write-Host '    [2]  Site Collection Admin  (added alongside existing admins)' -ForegroundColor White
    Write-Host '    [3]  Both Owner and Site Collection Admin' -ForegroundColor White
    Write-Host '    [B]  Back' -ForegroundColor White
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ''

    $permChoice = (Read-Host '  Enter choice').Trim().ToUpper()

    switch ($permChoice) {
        '1' { Invoke-GrantPermission -OneDriveUrl $OneDriveUrl -UserUPN $UserUPN -PermissionType 'Owner' -Config $Config }
        '2' { Invoke-GrantPermission -OneDriveUrl $OneDriveUrl -UserUPN $UserUPN -PermissionType 'Admin' -Config $Config }
        '3' { Invoke-GrantPermission -OneDriveUrl $OneDriveUrl -UserUPN $UserUPN -PermissionType 'Both'  -Config $Config }
        'B' { return }
        default {
            Write-Host "`n  Invalid option. Please enter 1, 2, 3, or B." -ForegroundColor Red
            Start-Sleep -Seconds 1
        }
    }
}

#endregion

#region Interactive Main Menu

function Show-MainMenu {
    param (
        [string]$OneDriveUrl,
        [string]$UserUPN
    )

    $urlIsSet = -not [string]::IsNullOrEmpty($OneDriveUrl)
    $upnIsSet = -not [string]::IsNullOrEmpty($UserUPN)

    Clear-Host
    Write-Host ''
    Write-Host '  +================================================+' -ForegroundColor Cyan
    Write-Host '  |   Change-OneDrivePermission                    |' -ForegroundColor Cyan
    Write-Host '  +================================================+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Current Selection:' -ForegroundColor White

    Write-Host '    [U] OneDrive URL  :  ' -NoNewline -ForegroundColor White
    if ($urlIsSet) {
        Write-Host $OneDriveUrl -ForegroundColor Yellow
    }
    else {
        Write-Host '(not set)' -ForegroundColor DarkGray
    }

    Write-Host '    [P] User UPN      :  ' -NoNewline -ForegroundColor White
    if ($upnIsSet) {
        Write-Host $UserUPN -ForegroundColor Yellow
    }
    else {
        Write-Host '(not set — required to grant permissions)' -ForegroundColor DarkGray
    }

    Write-Host ''
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray

    $checkColor  = if ($urlIsSet) { 'White' } else { 'DarkGray' }
    $grantColor  = if ($urlIsSet -and $upnIsSet) { 'White' } else { 'DarkGray' }
    $removeColor = if ($urlIsSet) { 'White' } else { 'DarkGray' }

    Write-Host '    [C]  Check Site Info  (Owner, Admins, Lock State, Archive Status)' -ForegroundColor $checkColor
    Write-Host '    [G]  Grant Permission' -ForegroundColor $grantColor
    Write-Host '    [R]  Remove Site Collection Admin' -ForegroundColor $removeColor
    Write-Host '    [Q]  Quit' -ForegroundColor White
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ''
}

function Start-InteractiveMenu {
    param ([hashtable]$Config)

    $currentUrl = [string]::Empty
    $currentUPN = [string]::Empty
    $exit       = $false

    while (-not $exit) {
        Show-MainMenu -OneDriveUrl $currentUrl -UserUPN $currentUPN
        $choice = (Read-Host '  Enter choice').Trim().ToUpper()

        switch ($choice) {
            'U' {
                Write-Host ''
                Write-Host '  OneDrive URL format:' -ForegroundColor DarkGray
                Write-Host '    https://contoso-my.sharepoint.com/personal/john_doe_contoso_com' -ForegroundColor DarkGray
                Write-Host ''

                $raw = (Read-Host '  OneDrive URL').Trim().TrimEnd('/')

                if ([string]::IsNullOrWhiteSpace($raw)) {
                    Write-Host '  URL cannot be empty.' -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    break
                }

                if (Test-OneDriveUrl -Url $raw) {
                    $currentUrl = $raw
                    Write-Log -Message "OneDrive URL set to: $currentUrl"
                }
                else {
                    Write-Host '  Invalid URL. Must be a OneDrive personal site root URL.' -ForegroundColor Red
                    Write-Host '  Example: https://contoso-my.sharepoint.com/personal/john_doe_contoso_com' -ForegroundColor DarkGray
                    Write-Log -Message "Invalid OneDrive URL entered: $raw" -Level Warning
                    Start-Sleep -Seconds 3
                }
            }

            'P' {
                Write-Host ''
                $raw = (Read-Host '  User UPN (e.g. john.doe@contoso.com)').Trim()

                if ([string]::IsNullOrWhiteSpace($raw)) {
                    Write-Host '  UPN cannot be empty.' -ForegroundColor Red
                    Start-Sleep -Seconds 1
                    break
                }

                $currentUPN = $raw
                Write-Log -Message "User UPN set to: $currentUPN"
            }

            'C' {
                if ([string]::IsNullOrEmpty($currentUrl)) {
                    Write-Host "`n  Please set a OneDrive URL first (press [U])." -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    break
                }
                Show-OneDriveSiteInfo -OneDriveUrl $currentUrl -Config $Config
            }

            'G' {
                if ([string]::IsNullOrEmpty($currentUrl)) {
                    Write-Host "`n  Please set a OneDrive URL first (press [U])." -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    break
                }
                if ([string]::IsNullOrEmpty($currentUPN)) {
                    Write-Host "`n  Please set a User UPN first (press [P])." -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    break
                }

                Show-PermissionSubMenu -OneDriveUrl $currentUrl -UserUPN $currentUPN -Config $Config
            }

            'R' {
                if ([string]::IsNullOrEmpty($currentUrl)) {
                    Write-Host "`n  Please set a OneDrive URL first (press [U])." -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    break
                }
                Invoke-RemoveSiteAdmin -OneDriveUrl $currentUrl -Config $Config
            }

            'Q' {
                Write-Log -Message 'Script terminated by user.'
                $exit = $true
            }

            default {
                Write-Host "`n  Invalid option. Press U, C, P, G, R, or Q." -ForegroundColor Red
                Start-Sleep -Seconds 1
            }
        }
    }

    Write-Host ''
    Write-Host '  Goodbye!' -ForegroundColor Cyan
    Write-Host ''
}

#endregion

#region Entry Point

Assert-PowerShellVersion
Assert-PnPModule

Write-Log -Message "Script started. Log file: $script:LogFile"

$appConfig = Resolve-AppConfig
Write-Log -Message "Configuration loaded. AppId: $($appConfig.AppId)  TenantId: $($appConfig.TenantId)"

Start-InteractiveMenu -Config $appConfig

Write-Log -Message 'Script completed.'

#endregion
