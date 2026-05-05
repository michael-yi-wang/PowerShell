#Requires -Version 7.0

<#
.SYNOPSIS
    Grants Owner and/or Site Collection Admin permissions on a OneDrive for Business site.

.DESCRIPTION
    Connects to a OneDrive for Business (personal site) using PnP.PowerShell with
    certificate-based app-only authentication. Provides an interactive menu to grant
    a specified user Owner and/or Site Collection Admin rights on a given OneDrive URL.

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
    Version  : 1.0.0
    Requires : PowerShell 7.0+, PnP.PowerShell module

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

function Assert-PnPModule {
    if (-not (Get-Module -ListAvailable -Name 'PnP.PowerShell')) {
        Write-Host ''
        Write-Host '  [ERROR] PnP.PowerShell module is not installed.' -ForegroundColor Red
        Write-Host '  Run the following command, then re-run this script:' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '    Install-Module -Name PnP.PowerShell -Scope CurrentUser' -ForegroundColor Cyan
        Write-Host ''
        exit 1
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
    # Sets the primary owner of the OneDrive site. Replaces any existing owner.
    [OutputType([bool])]
    param (
        [string]$UserUPN,
        [string]$SiteUrl
    )

    try {
        Write-Log -Message "Setting '$UserUPN' as owner of '$SiteUrl'."
        Set-PnPSite -Owner $UserUPN -ErrorAction Stop
        Write-Log -Message "Owner updated successfully."
        return $true
    }
    catch {
        Write-Log -Message "Failed to set owner '$UserUPN': $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Grant-OneDriveSiteAdmin {
    # Adds the user as a site collection admin. Existing admins are preserved.
    [OutputType([bool])]
    param (
        [string]$UserUPN,
        [string]$SiteUrl
    )

    try {
        Write-Log -Message "Adding '$UserUPN' as site collection admin of '$SiteUrl'."
        Add-PnPSiteCollectionAdmin -Owners @($UserUPN) -ErrorAction Stop
        Write-Log -Message "Site collection admin added successfully."
        return $true
    }
    catch {
        Write-Log -Message "Failed to add site collection admin '$UserUPN': $($_.Exception.Message)" -Level Error
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

    $connected = Connect-ToOneDriveSite -SiteUrl $OneDriveUrl -Config $Config
    if (-not $connected) {
        Write-Host ''
        Write-Host '  Unable to connect to the OneDrive site. Check the log for details.' -ForegroundColor Red
        Read-Host "`n  Press Enter to return to the menu"
        return
    }

    try {
        # Show existing site collection admins before making changes
        $existingAdmins = Get-CurrentSiteAdmins
        Write-Host ''
        Write-Host '  Current Site Collection Admins:' -ForegroundColor Cyan
        if ($existingAdmins.Count -gt 0) {
            foreach ($admin in $existingAdmins) {
                $display = if (-not [string]::IsNullOrEmpty($admin.Email)) {
                    "$($admin.Title) ($($admin.Email))"
                } else {
                    $admin.LoginName
                }
                Write-Host "    - $display" -ForegroundColor White
            }
        }
        else {
            Write-Host '    (none found)' -ForegroundColor DarkGray
        }

        # Summarise pending action and ask for confirmation
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
            Write-Log -Message "Permission grant cancelled by operator." -Level Warning
            Write-Host "`n  Operation cancelled." -ForegroundColor Yellow
            Read-Host "`n  Press Enter to return to the menu"
            return
        }

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

    Clear-Host
    Write-Host ''
    Write-Host '  +================================================+' -ForegroundColor Cyan
    Write-Host '  |   Change-OneDrivePermission                    |' -ForegroundColor Cyan
    Write-Host '  +================================================+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Current Selection:' -ForegroundColor White

    Write-Host '    [U] OneDrive URL  :  ' -NoNewline -ForegroundColor White
    if ([string]::IsNullOrEmpty($OneDriveUrl)) {
        Write-Host '(not set)' -ForegroundColor DarkGray
    }
    else {
        Write-Host $OneDriveUrl -ForegroundColor Yellow
    }

    Write-Host '    [P] User UPN      :  ' -NoNewline -ForegroundColor White
    if ([string]::IsNullOrEmpty($UserUPN)) {
        Write-Host '(not set)' -ForegroundColor DarkGray
    }
    else {
        Write-Host $UserUPN -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '    [G]  Grant Permission' -ForegroundColor White
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

            'Q' {
                Write-Log -Message 'Script terminated by user.'
                $exit = $true
            }

            default {
                Write-Host "`n  Invalid option. Press U, P, G, or Q." -ForegroundColor Red
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

Assert-PnPModule

Write-Log -Message "Script started. Log file: $script:LogFile"

$appConfig = Resolve-AppConfig
Write-Log -Message "Configuration loaded. AppId: $($appConfig.AppId)  TenantId: $($appConfig.TenantId)"

Start-InteractiveMenu -Config $appConfig

Write-Log -Message 'Script completed.'

#endregion
