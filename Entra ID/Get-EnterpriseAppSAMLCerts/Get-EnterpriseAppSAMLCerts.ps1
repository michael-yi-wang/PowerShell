<#
.SYNOPSIS
    Retrieves SAML-configured Enterprise Applications and their certificate details from Azure AD.

.DESCRIPTION
    This script connects to Microsoft Graph and retrieves all Enterprise Applications (Service Principals) 
    configured with SAML Single Sign-On. It extracts and displays certificate information including the 
    certificate thumbprint and expiration date for each SAML-enabled application.
    
    Results can be exported to a CSV file for audit purposes or certificate expiration tracking.

.PARAMETER Tenant
    Specifies the target Azure AD tenant ID or fully qualified domain name (FQDN).
    Example: "contoso.onmicrosoft.com" or "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"

.PARAMETER Output
    Specifies an optional folder path where the CSV report will be saved. 
    If this parameter is not provided, results are displayed in the console only.
    Example: "C:\Reports" or "C:\temp\EnterpriseAppCerts.csv"

.EXAMPLE
    .\Get-EnterpriseAppSAMLCerts.ps1 -Tenant "contoso.onmicrosoft.com"
    
    Retrieves and displays SAML enterprise application certificates from the specified tenant.

.EXAMPLE
    .\Get-EnterpriseAppSAMLCerts.ps1 -Tenant "contoso.onmicrosoft.com" -Output "C:\Reports"
    
    Retrieves SAML enterprise application certificates and exports the results to a CSV file in the specified directory.

.NOTES
    Author: Michael
    Date: December 12, 2025
    Version: 1.0
    
    Prerequisites:
    - Microsoft.Graph PowerShell module must be installed and imported
    - User must have sufficient permissions to read Enterprise Applications in Azure AD
    
    Requires the following Microsoft Graph permissions:
    - Application.Read.All

.LINK
    https://docs.microsoft.com/en-us/graph/api/serviceprincipal-list?view=graph-rest-1.0

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
                CertificateExpirationDate = $appCertInfo.KeyCredentials.endDateTime[0].ToString("yyyy-MM-dd")
            }
        }

        # Output
        if ($Output) {
            if (-not (Test-Path $Output)) {
                New-Item -ItemType Directory -Path $Output -Force | Out-Null
            }
            $fileName = "SAML_Apps_Report_$(Get-Date -Format 'yyyyMMdd-HHmmss').csv"
            $fullPath = Join-Path -Path $Output -ChildPath $fileName
            $results | Export-Csv -Path $fullPath -NoTypeInformation -Encoding UTF8
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
