<#
.SYNOPSIS
    Retrieve all Enterprise Applications (Service Principals) with SAML SSO configured.

.DESCRIPTION
    Connects to Microsoft Graph for the provided Tenant, retrieves Enterprise Applications with SAML SSO configured,
    and returns App Name, URI, Certificate Thumbprint, and Certificate Expiration Date.
    Can export results to a CSV file if an output folder is specified.

.PARAMETER Tenant
    The target Azure AD tenant ID or Domain.

.PARAMETER Output
    Optional. The folder path to save the CSV report. If not specified, output is displayed on screen.

.EXAMPLE
    .\Get-EnterpriseApp.ps1 -Tenant "contoso.onmicrosoft.com"

.EXAMPLE
    .\Get-EnterpriseApp.ps1 -Tenant "contoso.onmicrosoft.com" -Output "C:\Reports"
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$Tenant,

    [Parameter(Mandatory = $false)]
    [string]$Output
)

process {
    try {
        # Connect to Microsoft Graph
        Write-Verbose "Connecting to Microsoft Graph Tenant: $Tenant..."
        Connect-MgGraph -TenantId $Tenant -Scopes "Application.Read.All" -NoWelcome

        # Get all Service Principals
        # Fetching all service principals and filtering for SAML SSO
        Write-Verbose "Retrieving Enterprise Applications..."
        $servicePrincipals = Get-MgServicePrincipal -All -Property Id, DisplayName, AppId, IdentifierUris, KeyCredentials, PreferredSingleSignOnMode

        # Filter for SAML SSO
        $samlApps = $servicePrincipals | Where-Object { $_.PreferredSingleSignOnMode -eq 'saml' }

        $results = @()

        foreach ($app in $samlApps) {
            # Get Certificate Info
            # KeyCredentials contains the certificates.
            
            $appCertInfo = Invoke-MgGraphRequest -Method GET -Uri "https://graph.microsoft.com/v1.0/servicePrincipals/$($app.Id)?`$select=keyCredentials"

            $results += [PSCustomObject]@{
                AppName = $app.DisplayName
                CertificateExpirationDate = $appCertInfo.KeyCredentials.endDateTime[0]
            }
        }

        # Output
        if ($Output) {
            if (-not (Test-Path $Output)) {
                New-Item -ItemType Directory -Path $Output -Force | Out-Null
            }
            $fileName = "SAML_Apps_Report_$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
            $fullPath = Join-Path -Path $Output -ChildPath $fileName
            $results | Export-Csv -Path $fullPath -NoTypeInformation
            Write-Host "Report saved to: $fullPath" -ForegroundColor Green
        }
        else {
            $results | Format-Table -AutoSize
        }

    }
    catch {
        Write-Error "An error occurred: $_"
    }
}
