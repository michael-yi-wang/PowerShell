# Active Directory

## Overview

This folder contains PowerShell scripts for managing and automating tasks in Active Directory environments. Scripts may include domain controller checks, group management, user management, and reporting tools.

## Example Scripts

- **Scan-RequiredDCPorts.ps1**
      - Scans all mandatory ports required for domain controller operation.
      - Usage:
            ```powershell
            .\Scan-RequiredDCPorts.ps1 -TargetDC <DomainControllerFQDN>
            ```

## Prerequisites

- PowerShell 5.1 or later
- ActiveDirectory module

## Support

For issues or questions, please open an issue in the repository or contact the maintainer.

## License

MIT
