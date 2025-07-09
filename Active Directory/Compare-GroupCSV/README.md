# Compare-GroupCSV.ps1

## Overview

`Compare-GroupCSV.ps1` is a PowerShell script designed to compare two CSV files containing group information from On-Premises Active Directory and Entra ID (Azure AD). It matches groups based on their Security Identifier (SID) and reports which groups exist in both environments, along with relevant details.

## Features
- Compares On-Prem AD groups with Entra ID groups using the SID.
- Outputs a CSV report showing group presence and details in both systems.

## Parameters

| Parameter         | Type    | Description                                                      |
|-------------------|---------|------------------------------------------------------------------|
| `OnPremCsvPath`   | String  | Path to the On-Prem AD groups CSV file.                          |
| `EntraCsvPath`    | String  | Path to the Entra ID groups CSV file.                            |
| `OutputCsvPath`   | String  | Path where the comparison output CSV will be saved.               |

All parameters are mandatory.

## Input CSV Format

### On-Prem CSV
Should contain at least the following columns:
- `Group Name`
- `Group Type(String)`
- `Email`
- `SID`

### Entra CSV
Should contain at least the following columns:
- `DisplayName`
- `Id`
- `OnPremisesSecurityIdentifier`

## Output CSV Columns
- `OnPremGroupName`
- `OnPremGroupType`
- `OnPremGroupEmail`
- `OnPremGroupSID`
- `ExistInEntra` (True/False)
- `EntraGroupName`
- `EntraGroupID`

## Usage Example

```powershell
# Run the script with required parameters
pwsh -File Compare-GroupCSV.ps1 -OnPremCsvPath "C:\path\to\onprem.csv" -EntraCsvPath "C:\path\to\entra.csv" -OutputCsvPath "C:\path\to\output.csv"
```

## Notes
- Ensure both input CSVs have the required columns.
- The script will output a summary CSV and print a completion message. 