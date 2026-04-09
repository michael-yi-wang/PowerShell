# Get-EnterpriseAppSAMLCerts

Retrieves SAML-configured Enterprise Applications and their certificate details from Azure AD.

## Overview

This PowerShell script connects to Microsoft Graph and retrieves all Enterprise Applications (Service Principals) configured with SAML Single Sign-On. It extracts and displays certificate information including the certificate thumbprint and expiration date for each SAML-enabled application.

Results can be exported to a CSV file for audit purposes or certificate expiration tracking.

## Prerequisites

- **PowerShell 5.1 or later**
- **Microsoft.Graph PowerShell module** installed and imported
- **Azure AD/Entra ID Global Reader or Application Administrator** role (or equivalent permissions)
- Access to the target Azure AD tenant

### Required Graph Permissions

- `Application.Read.All` - Required to read Enterprise Applications and their certificate details

## Installation

1. Install the Microsoft Graph PowerShell module:

   ```powershell
   Install-Module -Name Microsoft.Graph -Scope CurrentUser
   ```

2. Download the script to your local machine.

## Usage

### Display Results on Console

```powershell
.\Get-EnterpriseAppSAMLCerts.ps1 -Tenant "contoso.onmicrosoft.com"
```

### Export Results to CSV

```powershell
.\Get-EnterpriseAppSAMLCerts.ps1 -Tenant "contoso.onmicrosoft.com" -Output "C:\Reports"
```

## Parameters

### Tenant (Required)

Specifies the target Azure AD tenant ID or fully qualified domain name (FQDN).

- **Type:** String
- **Example:** `contoso.onmicrosoft.com` or `xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx`

### Output (Optional)

Specifies an optional folder path where the CSV report will be saved. If this parameter is not provided, results are displayed in the console only.

- **Type:** String
- **Example:** `C:\Reports`

If the Output folder doesn't exist, it will be created automatically. The CSV file will be named with a timestamp: `SAML_Apps_Report_yyyyMMdd-HHmmss.csv`

## Output

The script generates a table or CSV file containing the following information for each SAML-configured enterprise application:

| Column | Description |
|--------|-------------|
| AppName | The display name of the Enterprise Application |
| CertificateExpirationDate | The certificate expiration date in yyyy-MM-dd format |

## Example Output

```powershell
AppName                    CertificateExpirationDate
-------                    ------------------------
Slack                      2024-12-31
ServiceNow                 2025-06-15
GitHub Enterprise          2025-11-20
```

## Notes

- **Author:** Michael
- **Version:** 1.0
- **Last Updated:** December 12, 2025

The script uses verbose output for troubleshooting. Run with the `-Verbose` flag to see detailed connection and retrieval information:

```powershell
.\Get-EnterpriseAppSAMLCerts.ps1 -Tenant "contoso.onmicrosoft.com" -Verbose
```

## Related Documentation

- [Microsoft Graph Service Principal API](https://docs.microsoft.com/en-us/graph/api/serviceprincipal-list?view=graph-rest-1.0)
- [Microsoft Graph PowerShell Module](https://docs.microsoft.com/en-us/powershell/microsoftgraph/overview?view=graph-powershell-1.0)
- [Azure AD SAML Token Certificates](https://docs.microsoft.com/en-us/azure/active-directory/develop/active-directory-certificate-based-authentication)

## Troubleshooting

### "The specified module 'Microsoft.Graph' could not be loaded"

Install the required module:

```powershell
Install-Module -Name Microsoft.Graph
```

### "Insufficient privileges to complete the operation"

Ensure your user account has the required Azure AD role (Global Reader or Application Administrator) or higher.

### Empty Results

Verify that you have enterprise applications configured with SAML SSO in your tenant. The script only returns applications where `PreferredSingleSignOnMode` is set to `'saml'`.
