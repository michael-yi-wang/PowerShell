# Exchange Online

## Overview

This folder contains PowerShell scripts for managing and automating tasks in Exchange Online and Office 365 mailboxes. Scripts may include mailbox management, reporting, permission changes, and troubleshooting tools.

## Prerequisites

- PowerShell 5.1 or later
- ExchangeOnlineManagement module
- Appropriate permissions in Exchange Online

## Usage

Connect to Exchange Online before running scripts:

```powershell
Connect-ExchangeOnline -UserPrincipalName <yourUPN>
```

Refer to each script's comments or documentation for specific usage instructions and required parameters.

## Example Scripts

- **Get-RecursiveDGMember.ps1**: Recursively retrieves all members of a distribution group, including nested groups.
- Other mailbox and permission management scripts

## Support

For issues or questions, please open an issue in the repository or contact the maintainer.

## License

MIT
