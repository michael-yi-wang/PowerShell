# Convert-SecurityGroup.ps1

This script converts Active Directory security group scopes (Global, Universal, DomainLocal) for a list of groups provided in a CSV. It validates parent-group scope compatibility, gathers all information up front, prompts for confirmation when needed, and logs all actions.

## Checklist

- Ensure you have a tested AD backup or snapshot (recommended)
- Run the script in a lab first and use `-WhatIf` for dry-runs
- Ensure AD replication is healthy before and after changes

## Prerequisites

- Windows PowerShell
- ActiveDirectory module (RSAT Active Directory cmdlets)
- Account with permission to modify AD groups (domain admin or delegated rights)

## Script path

`Convert-SecurityGroup.ps1` (same folder as this README)

## CSV input


The CSV must contain at least one of the following column headings (case-insensitive):

- `Group`
- `Name`
- `SamAccountName` or `sAMAccountName`
- `DistinguishedName`

Example CSV (simple):

# Convert-SecurityGroup.ps1

Convert the scope of Active Directory security groups from a CSV list.

This script reads a CSV of groups, gathers their current scope and parent-group memberships, warns about incompatible parent/child scope relationships, prompts for confirmation, and converts group scopes using `Set-ADGroup`. Actions and errors are logged to a timestamped log file in the CSV folder.

## Key features

- Accepts a CSV input and detects the column to use for group identity.
- Skips groups already in the desired scope.
- Detects parent-group scope conflicts (for example: a Global group cannot contain a Universal member) and prompts or aborts per user choice.
- Supports running AD queries locally or remotely on a specified domain controller (`-DomainController`); the script will prompt for credentials for the remote PSSession.
- Dry-run support via `-WhatIf`.

## Prerequisites

- Windows PowerShell (run as an account with appropriate AD permissions)
- RSAT ActiveDirectory module (imported automatically when available)
- When using `-DomainController`, ability to create a PSSession to that DC and valid credentials.

## CSV format

The CSV must contain at least one of the following column headings (case-insensitive):

- `Group`
- `Name`
- `SamAccountName` or `sAMAccountName`
- `DistinguishedName`

Example (minimal):

```csv
Group
SalesGroup
```

Or specify distinguished names:

```csv
DistinguishedName
CN=Sales,OU=Groups,DC=contoso,DC=com
```

The script will auto-detect the column to use.

## Usage

Local execution (uses AD cmdlets on the machine you run the script on):

```powershell
.\Convert-SecurityGroup.ps1 -TargetGroupScope Universal -CsvPath .\groups.csv
```

Remote execution on a specific domain controller (script prompts for credentials):

```powershell
.\Convert-SecurityGroup.ps1 -TargetGroupScope Global -CsvPath .\groups.csv -DomainController dc01.corp.contoso.com
```


## Safety and recommendations

- Always test in a lab or non-production environment first.
- Run with `-WhatIf` before doing real changes.
- Verify AD replication is healthy across domain controllers before and after changes.
- Have a rollback plan (restore from backup or AD snapshot) in case of mistakes.


## Troubleshooting

- "ActiveDirectory module is required" — install RSAT / import the module.
- "Group not found" — verify CSV values and that the account can read the group across the domain.
- Permissions errors — ensure the executing account has rights to modify group scope.
- Replication issues — run `repadmin /showrepl` and resolve replication errors first.
- Parent-scope conflicts — remove or modify parent memberships, or choose to skip conversion for that group.


## Notes

- The script uses `Get-ADGroup`, `Get-ADPrincipalGroupMembership`, and `Set-ADGroup`.
- Converting scopes may be restricted by membership relationships; the script prompts when it detects problematic parent scopes.

If you want additional features (CSV output of results, parallel conversions, or automated backup of AD objects), ask and a follow-up can be added.
