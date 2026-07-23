# Change-DNSNameServer

## Overview

Adds or removes a domain controller as a name server (NS record) across DNS
forward lookup zones. Intended for use during domain controller promotion
(add the new DC as a name server everywhere) and demotion (remove the old DC
as a name server everywhere).

The script checks each forward lookup zone's existing NS records first, so it
only changes zones that actually need it - zones where the name server is
already present (Add) or already absent (Remove) are skipped and logged.

## Prerequisites

- Must be run **on a domain controller** - the script verifies this via
  `Win32_ComputerSystem.DomainRole` and stops if it isn't.
- PowerShell 7.0 or later
- `DnsServer` PowerShell module (Windows DNS Server RSAT tools). This module
  is Windows-only; there is no cross-platform equivalent for managing Windows
  DNS Server zone data.
- Sufficient DNS administrative privileges on the target DNS server

## Parameters

| Parameter             | Mandatory | Parameter Set | Description                                                                                       |
|------------------------|-----------|----------------|---------------------------------------------------------------------------------------------------|
| `AddNameServer`        | Yes       | Add            | Adds `NameServerHostName` as a name server on each targeted zone that doesn't already have it.     |
| `RemoveNameServer`     | Yes       | Remove         | Removes `NameServerHostName` as a name server from each targeted zone that currently has it.       |
| `NameServerHostName`   | Yes       | Both           | FQDN of the domain controller to add or remove as a name server, e.g. `dc03.contoso.com`.          |
| `NameServerIPAddress`  | No        | Add            | IP address of the new DC. Used only to verify/log whether a matching A record already exists - no A records are created or modified. |
| `ZoneName`             | No        | Both           | Restrict the operation to one or more specific forward lookup zone(s). Default: all forward lookup zones. |
| `ExcludeZone`          | No        | Both           | Additional zone name(s) to skip, besides the built-in `TrustAnchors` zone (always excluded).       |
| `DnsServer`            | No        | Both           | DNS server to query/update. Defaults to the local computer name.                                   |
| `WhatIf`               | No        | Both           | Dry-run - shows what would change without making any changes.                                     |
| `Force`                | No        | Both           | Skips the interactive Y/N confirmation prompt.                                                     |

## Usage

Add a newly promoted DC as a name server on every forward lookup zone:
```powershell
.\Change-DNSNameServer.ps1 -AddNameServer -NameServerHostName dc03.contoso.com -NameServerIPAddress 10.0.0.13
```

Remove a demoted DC as a name server from a specific zone only, without prompting:
```powershell
.\Change-DNSNameServer.ps1 -RemoveNameServer -NameServerHostName dc01.contoso.com -ZoneName contoso.com -Force
```

Preview changes across all zones without applying them:
```powershell
.\Change-DNSNameServer.ps1 -AddNameServer -NameServerHostName dc03.contoso.com -WhatIf
```

## How It Works

1. **Domain controller check**: confirms the local machine's `DomainRole` is a primary or backup domain controller; stops otherwise.
2. **Module check**: confirms the `DnsServer` module is available; stops with install guidance otherwise.
3. **Zone enumeration**: retrieves forward lookup zones from the target DNS server, always excluding `TrustAnchors`, then applies `ZoneName`/`ExcludeZone` filters if given.
4. **Existing state check**: for each candidate zone, reads the current NS records and determines whether the target host is already present or absent. Zones that don't need a change are skipped and logged.
5. **Summary and confirmation**: displays the zones that will actually change and prompts for confirmation (unless `-Force`).
6. **Execution**: adds or removes the NS record on each zone that needs it, via `Add-DnsServerResourceRecord` / `Remove-DnsServerResourceRecord`.
7. **Output**: writes a timestamped log file and a CSV of per-zone results.

## Output Files

Both are saved in the script's folder, timestamped:

- **Change-DNSNameServer_\<timestamp\>.log** - full run log (Info/Warning/Error)
- **Change-DNSNameServer_Results_\<timestamp\>.csv** - per-zone results

### CSV columns

| Column          | Description                                      |
|-----------------|---------------------------------------------------|
| ZoneName        | Forward lookup zone name                          |
| Action          | `Add` or `Remove`                                  |
| PreviousState   | Whether the name server was `Present` or `Absent` before the change |
| Result          | `Success` or `Failed`                              |
| Message         | Detail message or error text                       |
| Timestamp       | Time the change was attempted                      |

## Notes

- This script only manages NS (name server) delegation records. It never
  creates, modifies, or deletes A (host) records - domain controllers
  self-register their own A records via dynamic DNS update, and cleanup of a
  demoted DC's A record/AD metadata is handled by normal DC demotion
  procedures.
- `-NameServerIPAddress` is informational only for the Add action (used to
  log whether an existing A record matches); it has no effect on Remove.
- Because it depends on the Windows-only `DnsServer` module, this script
  cannot run on macOS/Linux PowerShell hosts even though it targets
  PowerShell 7 syntax.
