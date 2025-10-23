<#
.SYNOPSIS
    Retrieve all Enterprise Applications (Service Principals) for a tenant and return App Name and Configured URL.

.DESCRIPTION
    Connects to Microsoft Graph (Microsoft.Graph PowerShell SDK) for the provided TenantId, enumerates enterprise applications (service principals)
    and returns a table with App Name and a best-effort Configured URL (homepage / replyUrls / redirectUris).

.PARAMETER TenantId
    The target Azure AD tenant ID (GUID or tenant domain). The script will call Connect-MgGraph -TenantId <TenantId>.

.EXAMPLE
    .\Get-EnterpriseApp.ps1 -TenantId "contoso.onmicrosoft.com"

.NOTES
    Requires Microsoft.Graph PowerShell SDK:
        Install-Module Microsoft.Graph -Scope CurrentUser
    Permissions: Application.Read.All or Application.ReadWrite.All depending on tenant restrictions.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, Position = 0)]
    [string]$TenantId
)

function Connect-GraphToTenant {
    param(
        [string]$TenantId
    )

    try {
        # Attempt to connect to Graph for the specified tenant. The account used must have permissions to read service principals.
        Connect-MgGraph -TenantId $TenantId -Scopes @('Application.Read.All') -ErrorAction Stop -NoWelcome
        Write-Verbose "Connected to Microsoft Graph for tenant: $TenantId"
    }
    catch {
        Write-Error "Failed to connect to Microsoft Graph for tenant '$TenantId': $($_.Exception.Message)"
        throw
    }
}

function Get-ConfiguredUrlFromServicePrincipal {
    param(
        [Parameter(Mandatory=$true)]
        $ServicePrincipal
    )

    # Try common properties for a configured URL in order of usefulness
    # 1) homepage (servicePrincipal.Homepage)
    # 2) servicePrincipal.AppRoles?? (not a URL)
    # 3) OAuth2Permissions / Reply URLs: servicePrincipal.ServicePrincipalNames or OAuth2AllowImplicitFlow (varies)
    # 4) Application object's web.redirectUris or web.homePage when available (requires fetching the application)

    if ($ServicePrincipal.Homepage) {
        return $ServicePrincipal.Homepage
    }

    # servicePrincipal.ServicePrincipalNames sometimes contains the appId URI; skip if it's an app URI (urn: or api://)
    if ($ServicePrincipal.ServicePrincipalNames) {
        $candidates = $ServicePrincipal.ServicePrincipalNames | Where-Object { $_ -match '^https?://' }
        if ($candidates) { return $candidates[0] }
    }

    # Try to fetch the underlying Application resource to inspect web.redirectUris or homepage
    try {
        $app = Get-MgApplication -Filter "appId eq '$($ServicePrincipal.AppId)'" -ErrorAction SilentlyContinue
        if ($app) {
            if ($app.Web -and $app.Web.RedirectUris -and $app.Web.RedirectUris.Count -gt 0) {
                return $app.Web.RedirectUris[0]
            }
            if ($app.Homepage) { return $app.Homepage }
            if ($app.Web -and $app.Web.Homepage) { return $app.Web.Homepage }
        }
    }
    catch {
        # ignore errors fetching the application object
    }

    return $null
}

# Main
try {
    Connect-GraphToTenant -TenantId $TenantId

    # Use Graph to list service principals (enterprise applications)
    # Fetch in pages using Invoke-MgGraphRequest to avoid long single requests that can hit the HttpClient timeout.
    $allServicePrincipals = @()
    $pageSize = 200  # reasonable page size to keep each HTTP call short
    $requestUri = "/servicePrincipals?Top=$pageSize"

    try {
        do {
            $resp = Invoke-MgGraphRequest -Method GET -Uri $requestUri -ErrorAction Stop
            if (-not $resp) { break }

            if ($resp.value) {
                $allServicePrincipals += $resp.value
            }

            # Next link may be returned in @odata.nextLink
            $next = $resp.'@odata.nextLink'
            if ($next) {
                # The next link is a full URL; pass it as the next requestUri
                $requestUri = $next
            }
            else {
                $requestUri = $null
            }
        } while ($requestUri)
    }
    catch {
        Write-Error "Failed to enumerate service principals: $($_.Exception.Message)"
        throw
    }

    $results = foreach ($sp in $allServicePrincipals) {
        $url = Get-ConfiguredUrlFromServicePrincipal -ServicePrincipal $sp
        [PSCustomObject]@{
            AppName = $sp.DisplayName
            AppId = $sp.AppId
            ConfiguredUrl = $url
        }
    }

    $results | Sort-Object AppName | Format-Table -AutoSize
}
catch {
    Write-Error "Script failed: $($_.Exception.Message)"
    exit 1
}
