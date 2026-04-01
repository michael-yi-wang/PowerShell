# Microsoft 365 Copilot App Usage Reporter

This PowerShell script generates a detailed usage report for Microsoft 365 Copilot across various applications (Teams, Word, Excel, PowerPoint, Outlook, OneNote, Loop, and Chat). It automatically enriches the usage data with organizational details from Entra ID, such as **Department** and **Office Location**.

## Features

- **Automated Data Retrieval:** Fetches usage metrics directly from the Microsoft Graph Beta Reports API.
- **Entra ID Enrichment:** Look up and attach `Department` and `OfficeLocation` for every user found in the report.
- **Smart Caching:** Optimizes performance by caching user details to minimize redundant API calls.
- **Comprehensive Logging:** Generates a detailed timestamped log file for auditing and troubleshooting.
- **Flexible Export:** Saves the final enriched report as a UTF-8 encoded CSV.

## Prerequisites

Before running the script, ensure you have the following installed:

1.  **PowerShell 5.1 or 7+**
2.  **Microsoft Graph PowerShell Modules:**
    - `Microsoft.Graph.Authentication`
    - `Microsoft.Graph.Users`

You can install them using:
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

### Required Permissions
The account running the script (or the App Registration used) requires the following Microsoft Graph scopes:
- `Reports.Read.All`
- `User.Read.All`

## Usage

Run the script by providing your Tenant ID. You can optionally specify the reporting period and output directories.

```powershell
.\Get-CopilotAppUsageReport.ps1 -TenantId "contoso.onmicrosoft.com" -Period D90
```

### Parameters

| Parameter | Description | Default |
| :--- | :--- | :--- |
| `TenantId` | **Required.** The ID or Name of the Microsoft 365 Tenant. | N/A |
| `Period` | The reporting window. Supported values: `D7`, `D30`, `D90`, `D180`. | `D30` |
| `OutputPath` | The directory where the CSV report will be saved. | `$PSScriptRoot` |
| `LogPath` | The directory where the log file will be saved. | `$PSScriptRoot` |

## Output

1.  **Usage Report:** `CopilotAppUsageReport_yyyyMMdd_HHmmss.csv`
2.  **Log File:** `CopilotReportLog_yyyyMMdd_HHmmss.txt`

The report includes the following columns:
- User Principal Name
- Display Name
- Department (Enriched)
- Office Location (Enriched)
- Last Activity Date (Per App: Teams, Word, Excel, etc.)
- Report Refresh Date
- Report Period

## License
This script is provided "as-is". Please test in a non-production environment before broad usage.
