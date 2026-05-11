#Requires -Version 7.0

<#
.SYNOPSIS
    Removes stale user profiles from SharePoint Online site collections.

.DESCRIPTION
    Connects to SharePoint Online using PnP.PowerShell with certificate-based
    app-only authentication. Provides an interactive menu to locate and optionally
    remove stale user profiles from individual SPO site collections.

    A "stale user" is an account that persists in a site's User Information List
    even though the user is no longer active in the organisation.

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
    .\Clear-SPOStaleUser.ps1 -AppId "00000000-0000-0000-0000-000000000000" `
                             -Thumbprint "ABC123DEF456..." `
                             -TenantId "contoso.onmicrosoft.com"

.EXAMPLE
    .\Clear-SPOStaleUser.ps1 -ConfigFile ".\config.json"

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
$script:LogFile = Join-Path -Path $script:LogDir -ChildPath "Clear-SPOStaleUser_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

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

function Test-SPOSiteCollectionUrl {
    # Accepts root, /sites/*, /teams/*, /portals/*, and personal site URLs.
    # Rejects sub-site paths (more than one path segment after the managed path).
    param ([string]$Url)

    $trimmed = $Url.TrimEnd('/')
    return $trimmed -match '^https://[a-zA-Z0-9][a-zA-Z0-9-]*(-my)?\.sharepoint\.com(/sites/[^/]+|/teams/[^/]+|/portals/[^/]+|/personal/[^/]+)?$'
}

function Resolve-AppConfig {
    # Returns a hashtable with AppId, Thumbprint, and TenantId.
    # Reads from a JSON file when the ConfigFile parameter set is active.
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

function Connect-ToSPOSite {
    [OutputType([bool])]
    param (
        [string]$SiteUrl,
        [hashtable]$Config
    )

    try {
        Write-Log -Message "Connecting to site: $SiteUrl"
        Connect-PnPOnline -Url $SiteUrl `
                          -ClientId  $Config.AppId `
                          -Thumbprint $Config.Thumbprint `
                          -Tenant    $Config.TenantId `
                          -ErrorAction Stop
        Write-Log -Message "Connection established."
        return $true
    }
    catch {
        Write-Log -Message "Connection failed for '$SiteUrl': $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Get-SPOSiteUser {
    # Returns the first matching SPO user object, or $null if not found.
    param ([string]$UserUPN)

    try {
        $allUsers = Get-PnPUser -ErrorAction Stop
        return ($allUsers | Where-Object { $_.Email -ieq $UserUPN })
    }
    catch {
        Write-Log -Message "Error retrieving site users: $($_.Exception.Message)" -Level Error
        return $null
    }
}

function Show-UserProfile {
    param (
        $User,
        [string]$SiteUrl
    )

    Write-Host ''
    Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
    Write-Host '  |  Stale User Profile Found                        |' -ForegroundColor Cyan
    Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
    Write-Host "  |  Site       : $SiteUrl"
    Write-Host "  |  Name       : $($User.Title)"
    Write-Host "  |  Email      : $($User.Email)"
    Write-Host "  |  Login Name : $($User.LoginName)"
    Write-Host "  |  User ID    : $($User.Id)"
    Write-Host "  |  Site Admin : $($User.IsSiteAdmin)"
    Write-Host '  +--------------------------------------------------+' -ForegroundColor Cyan
    Write-Host ''
}

function Remove-SPOSiteUser {
    [OutputType([bool])]
    param (
        $User,
        [string]$SiteUrl
    )

    try {
        # -Force suppresses the PnP cmdlet's own prompt; the operator already
        # confirmed removal via the interactive menu above.
        Remove-PnPUser -Identity $User.LoginName -Force -ErrorAction Stop
        Write-Log -Message "Removed user '$($User.Email)' (ID: $($User.Id)) from '$SiteUrl'."
        return $true
    }
    catch {
        Write-Log -Message "Failed to remove user '$($User.Email)': $($_.Exception.Message)" -Level Error
        return $false
    }
}

#endregion

#region Workflow

function Invoke-CheckAndRemoveUser {
    param (
        [string]$SiteUrl,
        [string]$UserUPN,
        [hashtable]$Config
    )

    Write-Log -Message "Starting check for '$UserUPN' on '$SiteUrl'."

    $connected = Connect-ToSPOSite -SiteUrl $SiteUrl -Config $Config
    if (-not $connected) {
        Write-Host '  Unable to connect to the site. Check the log for details.' -ForegroundColor Red
        Read-Host "`n  Press Enter to return to the menu"
        return
    }

    try {
        $user = Get-SPOSiteUser -UserUPN $UserUPN

        if ($null -ne $user) {
            Write-Log -Message "Profile found for '$UserUPN'."
            Show-UserProfile -User $user -SiteUrl $SiteUrl

            $confirm = Read-Host "  Remove '$UserUPN' from this site? (Y/N)"
            if ($confirm.Trim().ToUpper() -eq 'Y') {
                $removed = Remove-SPOSiteUser -User $user -SiteUrl $SiteUrl
                if ($removed) {
                    Write-Host "`n  User removed successfully." -ForegroundColor Green
                }
                else {
                    Write-Host "`n  Removal failed. Check the log for details." -ForegroundColor Red
                }
            }
            else {
                Write-Log -Message "Removal of '$UserUPN' cancelled by operator." -Level Warning
                Write-Host "`n  Operation cancelled." -ForegroundColor Yellow
            }
        }
        else {
            Write-Log -Message "User '$UserUPN' not found on '$SiteUrl'." -Level Warning
            Write-Host ''
            Write-Host "  User '$UserUPN' was not found on this site." -ForegroundColor Yellow
            Write-Host "  No stale profile exists — no action required." -ForegroundColor Yellow
        }
    }
    finally {
        try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
    }

    Read-Host "`n  Press Enter to return to the menu"
}

#endregion

#region Interactive Menu

function Show-MainMenu {
    param (
        [string]$SiteUrl,
        [string]$UserUPN
    )

    Clear-Host
    Write-Host ''
    Write-Host '  +================================================+' -ForegroundColor Cyan
    Write-Host '  |   Clear-SPOStaleUser  -  SPO User Management   |' -ForegroundColor Cyan
    Write-Host '  +================================================+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  Current Selection:' -ForegroundColor White

    Write-Host '    [S] Site URL  :  ' -NoNewline -ForegroundColor White
    if ([string]::IsNullOrEmpty($SiteUrl)) {
        Write-Host '(not set)' -ForegroundColor DarkGray
    }
    else {
        Write-Host $SiteUrl -ForegroundColor Yellow
    }

    Write-Host '    [U] User UPN  :  ' -NoNewline -ForegroundColor White
    if ([string]::IsNullOrEmpty($UserUPN)) {
        Write-Host '(not set)' -ForegroundColor DarkGray
    }
    else {
        Write-Host $UserUPN -ForegroundColor Yellow
    }

    Write-Host ''
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
    Write-Host '    [C]  Check & Remove Stale User' -ForegroundColor White
    Write-Host '    [Q]  Quit' -ForegroundColor White
    Write-Host '  ------------------------------------------------' -ForegroundColor DarkGray
    Write-Host ''
}

function Start-InteractiveMenu {
    param ([hashtable]$Config)

    $currentSiteUrl = [string]::Empty
    $currentUPN     = [string]::Empty
    $exit           = $false

    while (-not $exit) {
        Show-MainMenu -SiteUrl $currentSiteUrl -UserUPN $currentUPN
        $choice = (Read-Host '  Enter choice').Trim().ToUpper()

        switch ($choice) {
            'S' {
                Write-Host ''
                Write-Host '  Accepted formats:' -ForegroundColor DarkGray
                Write-Host '    https://contoso.sharepoint.com' -ForegroundColor DarkGray
                Write-Host '    https://contoso.sharepoint.com/sites/finance' -ForegroundColor DarkGray
                Write-Host '    https://contoso.sharepoint.com/teams/marketing' -ForegroundColor DarkGray
                Write-Host ''

                $raw = (Read-Host '  Site URL').Trim().TrimEnd('/')

                if ([string]::IsNullOrWhiteSpace($raw)) {
                    Write-Host '  URL cannot be empty.' -ForegroundColor Red
                    Start-Sleep -Seconds 2
                    break
                }

                if (Test-SPOSiteCollectionUrl -Url $raw) {
                    $currentSiteUrl = $raw
                    Write-Log -Message "Site URL set to: $currentSiteUrl"
                }
                else {
                    Write-Host '  Invalid URL. Only site collection root URLs are accepted (no sub-site paths).' -ForegroundColor Red
                    Write-Log -Message "Invalid site URL entered: $raw" -Level Warning
                    Start-Sleep -Seconds 2
                }
            }

            'U' {
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
                if ([string]::IsNullOrEmpty($currentSiteUrl)) {
                    Write-Host "`n  Please set a Site URL first (press [S])." -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    break
                }
                if ([string]::IsNullOrEmpty($currentUPN)) {
                    Write-Host "`n  Please set a User UPN first (press [U])." -ForegroundColor Yellow
                    Start-Sleep -Seconds 2
                    break
                }

                Invoke-CheckAndRemoveUser -SiteUrl $currentSiteUrl -UserUPN $currentUPN -Config $Config
            }

            'Q' {
                Write-Log -Message 'Script terminated by user.'
                $exit = $true
            }

            default {
                Write-Host "`n  Invalid option. Press S, U, C, or Q." -ForegroundColor Red
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
