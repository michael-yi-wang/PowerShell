# User and Group Existence Checker

`Test-UserGroupExistence.ps1` checks whether names listed in a CSV exist in on-premises Active Directory and (optionally) Azure AD / Entra ID.

## Why use this

- Quick audit to find missing or mismatched user and group objects across on-prem and Entra ID.
- Produces a CSV report with per-object status and timestamps.
- Non-destructive by default; Azure checks are optional and require connection.

## Prerequisites

- PowerShell (Windows PowerShell or PowerShell Core where modules are supported)
- Active Directory PowerShell module (RSAT) available on the host
- (Optional) Azure AD PowerShell module (`AzureAD`) when using `-ConnectToAzureAD`
- Appropriate read permissions for on-prem AD and/or Entra ID

## Usage

Run from PowerShell (examples use the script directory as current directory):

```powershell
# Basic (on-premises only)
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\objects.csv"

# Include Entra ID checks (will attempt Connect-AzureAD if not already connected)
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\objects.csv" -ConnectToAzureAD

# Custom column names and output path
.\Test-UserGroupExistence.ps1 -CsvPath "C:\data\items.csv" -NameColumn "DisplayName" -ObjectTypeColumn "Type" -OutputPath "C:\reports\existence.csv"
```

## Parameters

- `-CsvPath` (String, Mandatory): Path to the CSV file containing objects to check.
- `-ObjectTypeColumn` (String, Default: `ObjectType`): CSV column name that indicates object type (`User` or `Group`).
- `-NameColumn` (String, Default: `Name`): CSV column name that contains the object name to check (sAMAccountName, UPN, DisplayName, or group name depending on your CSV).
- `-OutputPath` (String, Default: `UserGroupExistenceReport.csv`): Where to save the results CSV.
- `-ConnectToAzureAD` (Switch): If supplied and not already connected, the script will call `Connect-AzureAD` and perform Entra ID checks.

## Expected CSV format

Minimum required columns (defaults):

```csv
Name,ObjectType
john.doe,User
IT_Support,Group
```

- `Name` values should be in a form accepted by AD cmdlets (`Get-ADUser -Identity`, `Get-ADGroup -Identity`) or by Azure queries (UPN, ObjectId, DisplayName depending on the search strategy).
- If your CSV uses different column names, pass `-NameColumn` and/or `-ObjectTypeColumn`.

## Behavior notes

- On-prem checks use `Get-ADUser -Identity` and `Get-ADGroup -Identity`.
- Azure checks try `Get-AzureADUser -ObjectId`, then `-SearchString`, and fall back to enumerating `Get-AzureADUser -All $true` and matching DisplayName when needed. Similar logic applies for groups.
- If Azure connection fails or `-ConnectToAzureAD` is not used, Azure checks are skipped and reported as such.
- Script emits colored console output and a progress bar. It is non-interactive.

## Output

The script produces a CSV with these columns:

- `Name` — original value from CSV
- `ObjectType` — original value from CSV
- `OnPremExists` — True / False / null (null indicates error during check)
- `AzureExists` — True / False / null (null indicates skipped or error)
- `OnPremDetails` — human-readable status for on-prem check
- `AzureDetails` — human-readable status for Azure check
- `Timestamp` — when the check was performed

## Troubleshooting

- "Active Directory PowerShell module is not installed": install RSAT or run on a domain-joined machine with AD modules.
- "Failed to connect to Azure AD": install `AzureAD` module and ensure credentials/network; use `-ConnectToAzureAD` to force connection.
- "Column not found in CSV file": verify the CSV contains the columns indicated by `-NameColumn` and `-ObjectTypeColumn`.
- Large Azure AD searches can be slow; prefer UPN/ObjectId in CSV to avoid full enumeration.

## Security

- Run with least-privilege accounts when possible.
- Keep input CSVs and exported reports in secure storage.

## License

This file follows the repository license.
