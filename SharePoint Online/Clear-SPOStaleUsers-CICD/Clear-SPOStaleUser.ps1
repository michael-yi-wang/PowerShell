#Requires -Version 7.0

<#
.SYNOPSIS
    Pipeline-mode script that finds or removes a stale user profile from a
    SharePoint Online site collection. Designed for unattended ADO pipeline use.

.DESCRIPTION
    Connects to SharePoint Online using PnP.PowerShell with certificate-based
    app-only authentication. Accepts all inputs as parameters — no interactive
    prompts are used anywhere in this script.

    Run with -CheckOnly to display the user profile without making changes
    (Stage 1 of the ADO pipeline). Run with -Force to remove the user after
    an approval gate has been satisfied (Stage 2 of the ADO pipeline).

    When running inside an Azure DevOps agent (TF_BUILD=True) log entries are
    written to stdout only. When running locally a timestamped log file is also
    created in a 'logs' sub-folder next to the script.

.PARAMETER AppId
    The Application (Client) ID of the Entra ID app registration used for
    app-only authentication.

.PARAMETER Thumbprint
    The SHA1 thumbprint of the certificate installed on the agent (or local
    machine) that matches the public key uploaded to the app registration.
    On Windows the certificate must be in the CurrentUser\My store.

.PARAMETER TenantId
    The Entra ID tenant ID (GUID) or primary domain
    (e.g. contoso.onmicrosoft.com).

.PARAMETER SiteUrl
    The SharePoint Online site collection URL to target. Must be a site
    collection root URL — sub-site paths are not accepted.

    Accepted formats:
        https://contoso.sharepoint.com
        https://contoso.sharepoint.com/sites/finance
        https://contoso.sharepoint.com/teams/marketing
        https://contoso-my.sharepoint.com/personal/john_contoso_com

.PARAMETER UserUPN
    The User Principal Name (UPN) of the account whose stale profile is to be
    inspected or removed. Example: john.doe@contoso.com

.PARAMETER CheckOnly
    When specified, the script retrieves and displays the user profile but does
    NOT remove the user. Mutually exclusive with -Force.

.PARAMETER Force
    When specified, the script removes the user from the site collection without
    an interactive confirmation prompt. This is safe in pipeline context because
    confirmation is provided by the ADO approval gate. Mutually exclusive with
    -CheckOnly.

.EXAMPLE
    .\Clear-SPOStaleUser.ps1 `
        -AppId      "00000000-0000-0000-0000-000000000000" `
        -Thumbprint "AABBCCDDEEFF..." `
        -TenantId   "contoso.onmicrosoft.com" `
        -SiteUrl    "https://contoso.sharepoint.com/sites/finance" `
        -UserUPN    "john.doe@contoso.com" `
        -CheckOnly

    Displays the stale user profile. No changes are made.

.EXAMPLE
    .\Clear-SPOStaleUser.ps1 `
        -AppId      "00000000-0000-0000-0000-000000000000" `
        -Thumbprint "AABBCCDDEEFF..." `
        -TenantId   "contoso.onmicrosoft.com" `
        -SiteUrl    "https://contoso.sharepoint.com/sites/finance" `
        -UserUPN    "john.doe@contoso.com" `
        -Force

    Removes the stale user profile. Intended for use after an ADO approval gate.

.NOTES
    Author   : Michael Wang
    Version  : 1.0.0
    Requires : PowerShell 7.0+, PnP.PowerShell module

    The Entra ID app registration must hold the SharePoint application permission:
        Sites.FullControl.All  (admin consent required)

    The certificate identified by Thumbprint must be installed in the agent's
    certificate store before this script is invoked. In the ADO pipeline this is
    handled by the 'Install certificate' PowerShell step that runs before this
    script.

    Exit codes:
        0 — Success (user found/removed, or not found — all expected outcomes)
        1 — Fatal error (validation failure, connection failure, removal failure)
#>

[CmdletBinding()]
param (
    [Parameter(Mandatory, HelpMessage = 'Entra ID Application (Client) ID')]
    [ValidateNotNullOrEmpty()]
    [string]$AppId,

    [Parameter(Mandatory, HelpMessage = 'Certificate thumbprint for app-only auth')]
    [ValidateNotNullOrEmpty()]
    [string]$Thumbprint,

    [Parameter(Mandatory, HelpMessage = 'Entra ID Tenant ID or primary domain')]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId,

    [Parameter(Mandatory, HelpMessage = 'SharePoint Online site collection URL')]
    [ValidateNotNullOrEmpty()]
    [string]$SiteUrl,

    [Parameter(Mandatory, HelpMessage = 'UPN of the user to inspect or remove')]
    [ValidateNotNullOrEmpty()]
    [string]$UserUPN,

    [Parameter(HelpMessage = 'Display profile only — no removal')]
    [switch]$CheckOnly,

    [Parameter(HelpMessage = 'Remove the user — no interactive confirmation')]
    [switch]$Force
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Initialisation

# Detect Azure DevOps agent context.
$script:IsAdoPipeline = ($env:TF_BUILD -eq 'True')

# Set up log file path (used only when running locally).
$script:LogDir  = Join-Path -Path $PSScriptRoot -ChildPath 'logs'
$script:LogFile = Join-Path -Path $script:LogDir `
    -ChildPath "Clear-SPOStaleUser_$(Get-Date -Format 'yyyyMMdd_HHmmss').log"

if (-not $script:IsAdoPipeline) {
    if (-not (Test-Path -Path $script:LogDir -PathType Container)) {
        New-Item -ItemType Directory -Path $script:LogDir -Force | Out-Null
    }
}

#endregion

#region Logging

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped log entry to the console and optionally to a file.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry     = "[$timestamp] [$($Level.ToUpper().PadRight(7))] $Message"

    # Write to log file when running locally (not in ADO pipeline).
    if (-not $script:IsAdoPipeline) {
        Add-Content -Path $script:LogFile -Value $entry -Encoding UTF8
    }

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
    <#
    .SYNOPSIS
        Verifies PnP.PowerShell is available and imports it. Exits with code 1
        if the module is not installed.
    #>
    if (-not (Get-Module -ListAvailable -Name 'PnP.PowerShell')) {
        Write-Host ''
        Write-Host '  [ERROR] PnP.PowerShell module is not installed.' -ForegroundColor Red
        Write-Host '  Run the following command and then re-run this script:' -ForegroundColor Yellow
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
    <#
    .SYNOPSIS
        Returns $true if the URL matches a valid SPO site collection pattern.
        Accepts root, /sites/*, /teams/*, /portals/*, and /personal/* paths.
        Rejects sub-site paths (more than one segment after the managed path).
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Url
    )

    $trimmed = $Url.TrimEnd('/')
    return $trimmed -match '^https://[a-zA-Z0-9][a-zA-Z0-9-]*(-my)?\.sharepoint\.com(/sites/[^/]+|/teams/[^/]+|/portals/[^/]+|/personal/[^/]+)?$'
}

#endregion

#region SPO Operations

function Connect-ToSPOSite {
    <#
    .SYNOPSIS
        Establishes a PnP connection to an SPO site collection using app-only
        certificate authentication. Returns $true on success, $false on failure.
    #>
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        [string]$SiteUrl,

        [Parameter(Mandatory)]
        [string]$AppId,

        [Parameter(Mandatory)]
        [string]$Thumbprint,

        [Parameter(Mandatory)]
        [string]$TenantId
    )

    try {
        Write-Log -Message "Connecting to site: $SiteUrl"
        Connect-PnPOnline -Url        $SiteUrl `
                          -ClientId   $AppId `
                          -Thumbprint $Thumbprint `
                          -Tenant     $TenantId `
                          -ErrorAction Stop
        Write-Log -Message 'Connection established.'
        return $true
    }
    catch {
        Write-Log -Message "Connection failed for '$SiteUrl': $($_.Exception.Message)" -Level Error
        return $false
    }
}

function Get-SPOSiteUser {
    <#
    .SYNOPSIS
        Returns the SPO user object whose Email matches UserUPN (case-insensitive),
        or $null if not found.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$UserUPN
    )

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
    <#
    .SYNOPSIS
        Prints a formatted summary box of the located SPO user profile.
    #>
    param (
        [Parameter(Mandatory)]
        $User,

        [Parameter(Mandatory)]
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
    <#
    .SYNOPSIS
        Removes the specified user from the SPO site's User Information List.
        -Force is used on the PnP cmdlet because the ADO approval gate already
        serves as the confirmation step. Returns $true on success, $false on failure.
    #>
    [OutputType([bool])]
    param (
        [Parameter(Mandatory)]
        $User,

        [Parameter(Mandatory)]
        [string]$SiteUrl
    )

    try {
        # -Force suppresses PnP's own confirmation prompt; the operator has already
        # approved removal via the ADO environment approval gate.
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

#region Entry Point

# --- Validate operating mode: exactly one of -CheckOnly or -Force is required ---
if ($CheckOnly -and $Force) {
    Write-Error '-CheckOnly and -Force are mutually exclusive. Specify exactly one.'
    exit 1
}
if (-not $CheckOnly -and -not $Force) {
    Write-Error 'You must specify either -CheckOnly (inspect only) or -Force (remove user).'
    exit 1
}

# --- Validate SiteUrl format ---
if (-not (Test-SPOSiteCollectionUrl -Url $SiteUrl)) {
    Write-Error "Invalid SiteUrl '$SiteUrl'. Must be a SharePoint Online site collection root URL."
    exit 1
}

# Normalise trailing slash
$SiteUrl = $SiteUrl.TrimEnd('/')

# --- Determine and log the operating mode ---
$mode = if ($CheckOnly) { 'CheckOnly' } else { 'Force (removal)' }

Assert-PnPModule

Write-Log -Message "Script started. Mode: $mode  |  Site: $SiteUrl  |  User: $UserUPN"

# --- Connect ---
$connected = Connect-ToSPOSite -SiteUrl    $SiteUrl `
                                -AppId      $AppId `
                                -Thumbprint $Thumbprint `
                                -TenantId   $TenantId

if (-not $connected) {
    Write-Log -Message 'Cannot continue — SPO connection failed.' -Level Error
    exit 1
}

try {
    # --- Locate user ---
    $user = Get-SPOSiteUser -UserUPN $UserUPN

    if ($null -ne $user) {
        Write-Log -Message "Profile found for '$UserUPN'."
        Show-UserProfile -User $user -SiteUrl $SiteUrl

        if ($CheckOnly) {
            Write-Log -Message 'CheckOnly mode — no changes made.'
            Write-Host ''
            Write-Host '  +--------------------------------------------------+' -ForegroundColor Yellow
            Write-Host '  |  CHECK-ONLY MODE: No changes have been made.     |' -ForegroundColor Yellow
            Write-Host '  |  Approve Stage 2 in the pipeline to remove.      |' -ForegroundColor Yellow
            Write-Host '  +--------------------------------------------------+' -ForegroundColor Yellow
            Write-Host ''
        }
        else {
            # Force mode — approval gate already cleared in ADO.
            Write-Log -Message "Removing user '$UserUPN' from '$SiteUrl'."
            $removed = Remove-SPOSiteUser -User $user -SiteUrl $SiteUrl

            if (-not $removed) {
                Write-Log -Message 'User removal failed. See log entry above.' -Level Error
                exit 1
            }

            Write-Host ''
            Write-Host '  User removed successfully.' -ForegroundColor Green
            Write-Host ''
        }
    }
    else {
        Write-Log -Message "User '$UserUPN' was not found on '$SiteUrl'." -Level Warning
        Write-Host ''
        Write-Host "  User '$UserUPN' was not found on this site." -ForegroundColor Yellow
        Write-Host '  No stale profile exists — no action required.' -ForegroundColor Yellow
        Write-Host ''
    }
}
finally {
    try { Disconnect-PnPOnline -ErrorAction SilentlyContinue } catch {}
}

Write-Log -Message 'Script completed.'

#endregion
