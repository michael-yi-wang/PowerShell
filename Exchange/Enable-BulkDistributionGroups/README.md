
# Enable-BulkDistributionGroups.ps1

## Overview

`Enable-BulkDistributionGroups.ps1` is a PowerShell script designed to bulk mail-enable distribution groups in an on-premises Exchange environment using a CSV input file. It also supports optionally hiding groups from the Global Address List (GAL) and logs all actions to separate success and failure CSV files.

## Features

- Validates that it is running on an on-prem Exchange server.
- Accepts a CSV file with required headers: `Name` and `PrimarySMTPAddress`.
- Optionally hides groups from the GAL with the `-HiddenFromGAL` parameter.
- Prompts for user confirmation before making changes.
- Logs successful and failed operations to separate CSV files.

## Parameters

- `-CsvFile` (mandatory): Path to the CSV file containing distribution group information. The CSV must have the columns `Name` and `PrimarySMTPAddress`.
- `-HiddenFromGAL` (optional): Boolean. If `$true`, hides the group from the GAL. Default is `$false`.

## CSV Format

The input CSV file must contain the following headers:

```csv
Name,PrimarySMTPAddress
Group1,group1@example.com
Group2,group2@example.com
```

## Usage

```powershell
# Basic usage
.\Enable-BulkDistributionGroups.ps1 -CsvFile .\groups.csv

# Hide groups from GAL
.\Enable-BulkDistributionGroups.ps1 -CsvFile .\groups.csv -HiddenFromGAL $true
```

## Logging

- Successes are logged to `Enable-BulkDistributionGroups_Success_<timestamp>.csv`.
- Failures are logged to `Enable-BulkDistributionGroups_Fail_<timestamp>.csv`.
- Log files are saved in the same directory as the input CSV file.

## Requirements

- Must be run on an on-prem Exchange server with the Exchange Management Shell.
- Appropriate permissions to mail-enable distribution groups.

## Notes

- The script will abort if not run in the correct environment or if the CSV is invalid.
- User confirmation is required before any changes are made.
