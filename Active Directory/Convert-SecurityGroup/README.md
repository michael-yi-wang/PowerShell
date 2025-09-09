
# Convert-SecurityGroup.ps1

This script converts Active Directory security group scopes (Global, Universal, DomainLocal) for a list of groups provided in a CSV. It validates parent-group scope compatibility, prompts for confirmation, and logs all actions.

## Key Features

- Accepts a CSV input and auto-detects the column to use for group identity.
- Skips groups already in the desired scope.
- Detects parent-group scope conflicts (e.g., a Global group cannot contain a Universal member).
- If parent conflicts exist, lists the parent groups and offers to convert them first. The script will not proceed with member conversions until parent conflicts are resolved and the user confirms.
- Supports running AD queries locally or remotely on a specified domain controller (`-DomainController`); prompts for credentials for remote PSSession.
- Dry-run support via `-WhatIf`.
- All actions and errors are logged to a timestamped log file in the CSV folder.

## Prerequisites

- Windows PowerShell (run as an account with appropriate AD permissions)
- RSAT ActiveDirectory module (imported automatically when available)
- When using `-DomainController`, ability to create a PSSession to that DC and valid credentials.

## CSV Format

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

## Usage

Local execution (uses AD cmdlets on the machine you run the script on):

```powershell
./Convert-SecurityGroup.ps1 -TargetGroupScope Universal -CsvPath ./groups.csv
```

Remote execution on a specific domain controller (script prompts for credentials):

```powershell
./Convert-SecurityGroup.ps1 -TargetGroupScope Global -CsvPath ./groups.csv -DomainController dc01.corp.contoso.com
```

## Workflow

1. The script reads the CSV and gathers group and parent-group information.
2. It checks for parent-group scope conflicts (e.g., Global parent with Universal member).
3. If conflicts exist, it lists the parent groups and asks if you want to convert them to the target scope first. If you agree, it attempts to convert the parents and aborts if any fail or conflicts remain.
4. After parent conversion, the script asks for confirmation before proceeding with member group conversions.
5. If you confirm, the script converts the member groups to the target scope.
6. All actions and errors are logged to a timestamped log file in the CSV folder.

## Safety and Recommendations

- Always test in a lab or non-production environment first.
- Run with `-WhatIf` before making real changes.
- Verify AD replication is healthy across domain controllers before and after changes.
- Have a rollback plan (restore from backup or AD snapshot) in case of mistakes.

## Troubleshooting

- "ActiveDirectory module is required" — install RSAT / import the module.
- "Group not found" — verify CSV values and that the account can read the group across the domain.
- Permissions errors — ensure the executing account has rights to modify group scope.
- Replication issues — run `repadmin /showrepl` and resolve replication errors first.
- Parent-scope conflicts — convert parent groups first as prompted by the script.

## Notes

- The script uses `Get-ADGroup`, `Get-ADPrincipalGroupMembership`, and `Set-ADGroup`.
- Converting scopes may be restricted by membership relationships; the script prompts when it detects problematic parent scopes.

If you want additional features (CSV output of results, parallel conversions, or automated backup of AD objects), ask and a follow-up can be added.
