# PowerShell

This repository contains PowerShell scripts for system administration and automation across multiple Microsoft platforms.

## Repository Structure

- **Active Directory**: Scripts for managing on-premises AD objects and tasks
- **Entra ID**: Scripts for Microsoft Entra ID (Azure AD) management and automation
- **Exchange**: Scripts for on-premises Exchange server management
- **Exchange Online**: Scripts for Exchange Online and Office 365 mailbox management

## Requirements

- PowerShell 5.1 or later
- Modules:
  - `ActiveDirectory` (for on-prem AD)
  - `Microsoft.Graph` (for Entra ID)
  - `ExchangeOnlineManagement` (for Exchange Online)

To install the required modules, run:

```powershell
Install-Module ActiveDirectory
Install-Module Microsoft.Graph
Install-Module ExchangeOnlineManagement
```

## Issue Reporting

If you encounter issues or have suggestions, please open an issue in this repository.
