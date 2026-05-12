#Requires -Version 7.0

<#
.SYNOPSIS
    Removes stale user profiles from SharePoint Online site collections, using
    Azure Key Vault as the authoritative source for all connection secrets.

.DESCRIPTION
    Connects to SharePoint Online using PnP.PowerShell with certificate-based
    app-only authentication. Provides an interactive menu to locate and optionally
    remove stale user profiles from individual SPO site collections.

    A "stale user" is an account that persists in a site's User Information List
    even though the user is no longer active in the organisation.

    CONFIGURATION (NO PARAMETERS REQUIRED)
    ---------------------------------------
    All configuration is sourced from:
      1. Four non-secret environment variables set by Intune / GPO (see below).
      2. Three secrets stored in Azure Key Vault, retrieved at runtime via the
         service principal certificate.

    Required environment variables (set by your IT administrator):
      SPO_APP_ID          – Entra ID Application (Client) ID
      SPO_TENANT_ID       – Entra ID Tenant ID or primary domain
      SPO_KV_URL          – Azure Key Vault URL  (e.g. https://contoso-spo-kv.vault.azure.net)
      SPO_CERT_THUMBPRINT – SHA1 thumbprint of the SP certificate installed locally

    Azure Key Vault secrets (created by admin):
      spo-app-id     – Client ID (admin-managed copy)
      spo-tenant-id  – Tenant ID (admin-managed copy)
      spo-thumbprint – Current certificate thumbprint (renewal signal)

    HELPDESK USE
    ------------
    Run the script with no parameters. It will read the four environment variables,
    connect silently to Azure Key Vault, retrieve the connection secrets, and then
    launch the familiar interactive menu.
    Contact your IT administrator if the script fails before the menu appears.

    CERTIFICATE RENEWAL
    -------------------
    The IT administrator updates the spo-thumbprint secret in Key Vault FIRST.
    The script will emit a thumbprint-mismatch warning (expected during roll-out)
    but will continue using the Key Vault value. Once the new certificate reaches
    all helpdesk machines the environment variable is updated via Intune policy.

.EXAMPLE
    .\Clear-SPOStaleUser.ps1

    No parameters needed. Configuration is sourced from environment variables and
    Azure Key Vault automatically.

.NOTES
    Author   : Michael Wang
    Version  : 2.0.0
    Requires : PowerShell 7.0+, PnP.PowerShell module, Az.Accounts module, Az.KeyVault module

    The Entra ID app registration must hold the SharePoint application permission:
        Sites.FullControl.All  (admin consent required)

    The app registration's service principal must hold the Key Vault RBAC role:
        Key Vault Secrets User  (on the Key Vault resource)

    The signing certificate identified by SPO_CERT_THUMBPRINT must be installed in
    the local certificate store (CurrentUser\My) before running this script.
#>

[CmdletBinding()]
param ()

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
        Write-Host '    Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force' -ForegroundColor Cyan
        Write-Host ''
        exit 1
    }
    Import-Module -Name 'PnP.PowerShell' -ErrorAction Stop
    Write-Log -Message 'PnP.PowerShell module loaded.'
}

function Assert-AzModules {
    $required = @('Az.Accounts', 'Az.KeyVault')
    $missing  = $required | Where-Object { -not (Get-Module -ListAvailable -Name $_) }

    if ($missing.Count -gt 0) {
        Write-Host ''
        Write-Host '  [ERROR] One or more required Az modules are not installed:' -ForegroundColor Red
        $missing | ForEach-Object { Write-Host "          - $_" -ForegroundColor Yellow }
        Write-Host ''
        Write-Host '  Run the following commands, then re-run this script:' -ForegroundColor Yellow
        Write-Host ''
        Write-Host '    Install-Module -Name Az.Accounts -Scope CurrentUser -Force' -ForegroundColor Cyan
        Write-Host '    Install-Module -Name Az.KeyVault -Scope CurrentUser -Force' -ForegroundColor Cyan
        Write-Host ''
        exit 1
    }

    foreach ($mod in $required) {
        Import-Module -Name $mod -ErrorAction Stop
    }
    Write-Log -Message 'Az.Accounts and Az.KeyVault modules loaded.'
}

#endregion

#region Key Vault

function Resolve-AppConfig {
    <#
    .SYNOPSIS
        Reads four environment variables, authenticates to Azure Key Vault as a
        service principal using the local certificate, retrieves the three KV
        secrets, and returns a configuration hashtable.
    .OUTPUTS
        [hashtable] with keys: AppId, TenantId, Thumbprint
    #>
    [OutputType([hashtable])]
    param ()

    # ── Step 1: Read environment variables ────────────────────────────────────
    $envAppId      = $env:SPO_APP_ID
    $envTenantId   = $env:SPO_TENANT_ID
    $envKvUrl      = $env:SPO_KV_URL
    $envThumbprint = $env:SPO_CERT_THUMBPRINT

    $missingVars = @()
    if ([string]::IsNullOrWhiteSpace($envAppId))      { $missingVars += 'SPO_APP_ID' }
    if ([string]::IsNullOrWhiteSpace($envTenantId))   { $missingVars += 'SPO_TENANT_ID' }
    if ([string]::IsNullOrWhiteSpace($envKvUrl))      { $missingVars += 'SPO_KV_URL' }
    if ([string]::IsNullOrWhiteSpace($envThumbprint)) { $missingVars += 'SPO_CERT_THUMBPRINT' }

    # ── Step 2: Validate all four are present ─────────────────────────────────
    if ($missingVars.Count -gt 0) {
        Write-Host ''
        Write-Host '  [ERROR] The following required environment variables are not set:' -ForegroundColor Red
        $missingVars | ForEach-Object { Write-Host "          - $_" -ForegroundColor Yellow }
        Write-Host ''
        Write-Host '  These variables must be configured by your IT administrator.' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  Required environment variables:' -ForegroundColor White
        Write-Host '  +----------------------+---------------------------------------------------+' -ForegroundColor DarkGray
        Write-Host '  | Variable             | Example value                                     |' -ForegroundColor DarkGray
        Write-Host '  +----------------------+---------------------------------------------------+' -ForegroundColor DarkGray
        Write-Host '  | SPO_APP_ID           | xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx              |' -ForegroundColor DarkGray
        Write-Host '  | SPO_TENANT_ID        | xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx              |' -ForegroundColor DarkGray
        Write-Host '  | SPO_KV_URL           | https://<vault-name>.vault.azure.net              |' -ForegroundColor DarkGray
        Write-Host '  | SPO_CERT_THUMBPRINT  | XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX          |' -ForegroundColor DarkGray
        Write-Host '  +----------------------+---------------------------------------------------+' -ForegroundColor DarkGray
        Write-Host ''
        Write-Host '  Contact your IT administrator to have these set via Intune policy.' -ForegroundColor Cyan
        Write-Host ''
        exit 1
    }

    Write-Log -Message 'All required environment variables are present.'

    # ── Step 3: Locate the certificate in the local store ─────────────────────
    $certPath = "Cert:\CurrentUser\My\$envThumbprint"
    try {
        $cert = Get-Item -Path $certPath -ErrorAction Stop
        Write-Log -Message "Certificate found in CurrentUser\My (thumbprint: $envThumbprint)."
    }
    catch {
        Write-Host ''
        Write-Host "  [ERROR] Certificate with thumbprint '$envThumbprint' was not found in CurrentUser\My." -ForegroundColor Red
        Write-Host ''
        Write-Host '  Verify the certificate is installed by running:' -ForegroundColor Cyan
        Write-Host '    Get-ChildItem Cert:\CurrentUser\My | Select-Object Thumbprint, Subject' -ForegroundColor Cyan
        Write-Host ''
        Write-Host '  Contact your IT administrator if the certificate is missing.' -ForegroundColor Cyan
        Write-Host ''
        exit 1
    }

    # ── Step 4: Authenticate to Azure as service principal ────────────────────
    Write-Log -Message "Authenticating to Azure (TenantId: $envTenantId, AppId: $envAppId)."
    try {
        Connect-AzAccount -ServicePrincipal `
                          -CertificateThumbprint $envThumbprint `
                          -ApplicationId $envAppId `
                          -Tenant $envTenantId `
                          -ErrorAction Stop | Out-Null
        Write-Log -Message 'Azure authentication successful.'
    }
    catch {
        Write-Log -Message "Azure authentication failed: $($_.Exception.Message)" -Level Error
        Write-Host ''
        Write-Host '  [ERROR] Failed to authenticate to Azure.' -ForegroundColor Red
        Write-Host '  Verify the app registration has the Key Vault Secrets User role on the Key Vault.' -ForegroundColor Cyan
        Write-Host ''
        exit 1
    }

    # ── Step 5: Derive Key Vault name from the URL ────────────────────────────
    $kvName = ([Uri]$envKvUrl).Host.Split('.')[0]
    Write-Log -Message "Resolved Key Vault name: $kvName"

    # ── Step 6: Retrieve secrets from Key Vault ───────────────────────────────
    $secretNames = @{
        AppId      = 'spo-app-id'
        TenantId   = 'spo-tenant-id'
        Thumbprint = 'spo-thumbprint'
    }

    $kvValues = @{}
    foreach ($key in $secretNames.Keys) {
        $secretName = $secretNames[$key]
        try {
            $value = Get-AzKeyVaultSecret -VaultName $kvName -Name $secretName -AsPlainText -ErrorAction Stop
            if ([string]::IsNullOrWhiteSpace($value)) {
                throw "Secret '$secretName' exists but is empty."
            }
            $kvValues[$key] = $value
            Write-Log -Message "Retrieved secret '$secretName' from Key Vault."
        }
        catch {
            Write-Log -Message "Failed to retrieve Key Vault secret '$secretName': $($_.Exception.Message)" -Level Error
            Write-Host ''
            Write-Host "  [ERROR] Could not retrieve secret '$secretName' from Key Vault '$kvName'." -ForegroundColor Red
            Write-Host ''
            Write-Host '  Ensure the following secrets have been created by your administrator:' -ForegroundColor Cyan
            Write-Host '    spo-app-id     (Application Client ID)' -ForegroundColor Cyan
            Write-Host '    spo-tenant-id  (Tenant ID or primary domain)' -ForegroundColor Cyan
            Write-Host '    spo-thumbprint (Certificate thumbprint)' -ForegroundColor Cyan
            Write-Host ''
            Write-Host '  Contact your IT administrator.' -ForegroundColor Cyan
            Write-Host ''
            exit 1
        }
    }

    # ── Step 7: Cross-check thumbprint (mismatch = renewal in progress) ───────
    $kvThumbprint = $kvValues['Thumbprint']
    if ($kvThumbprint -ne $envThumbprint) {
        Write-Log -Message "Thumbprint mismatch: KV has '$kvThumbprint', env var has '$envThumbprint'. Certificate renewal may be pending." -Level Warning
        Write-Host ''
        Write-Host '  [WARNING] Thumbprint mismatch detected.' -ForegroundColor Yellow
        Write-Host "  Key Vault thumbprint : $kvThumbprint" -ForegroundColor Yellow
        Write-Host "  Env var thumbprint   : $envThumbprint" -ForegroundColor Yellow
        Write-Host '  This is expected during certificate renewal roll-out.' -ForegroundColor Yellow
        Write-Host '  Continuing with the Key Vault value (source of truth).' -ForegroundColor Yellow
        Write-Host ''
    }

    # ── Step 8: Return KV-sourced configuration ───────────────────────────────
    return @{
        AppId      = $kvValues['AppId']
        TenantId   = $kvValues['TenantId']
        Thumbprint = $kvThumbprint
    }
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
                          -ClientId   $Config.AppId `
                          -Thumbprint $Config.Thumbprint `
                          -Tenant     $Config.TenantId `
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

Assert-AzModules
Assert-PnPModule

Write-Log -Message "Script started. Log file: $script:LogFile"

$appConfig = Resolve-AppConfig
Write-Log -Message "Configuration loaded from Key Vault. AppId: $($appConfig.AppId)  TenantId: $($appConfig.TenantId)"

Start-InteractiveMenu -Config $appConfig

Write-Log -Message 'Script completed.'

#endregion
