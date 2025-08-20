# Entra ID

## Overview

This folder contains PowerShell scripts and resources for managing and automating tasks in Microsoft Entra ID (Azure Active Directory). Scripts may include user, group, application, and authentication management, as well as reporting and troubleshooting tools.

## Prerequisites

- PowerShell 5.1 or later
- Microsoft Graph PowerShell module (`Microsoft.Graph`)
- Appropriate permissions in Azure AD/Entra ID

## Usage

Import or run scripts as needed. Most scripts require you to connect to Microsoft Graph:

```powershell
Connect-MgGraph -Scopes "User.Read.All, Group.Read.All, Directory.Read.All"
```

Refer to each script's comments or documentation for specific usage instructions and required parameters.

## Example Scripts

- **Get-RecursiveGroupMember.ps1**: Recursively retrieves all members of a group, including nested groups.
- **Check-ADGroupExistenceInEntra.ps1**: Compares on-premises AD groups with Entra ID groups.

## Support

For issues or questions, please open an issue in the repository or contact the maintainer.

## License

MIT
