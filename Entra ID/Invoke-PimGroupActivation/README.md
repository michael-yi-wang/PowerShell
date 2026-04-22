# Invoke-PimGroupActivation

An interactive PowerShell script to manage and activate **Microsoft Entra ID Privileged Identity Management (PIM) for Groups** assignments.

## Overview

`Invoke-PimGroupActivation.ps1` simplifies the process of activating eligible group assignments. It provides an interactive menu that allows users to view their current eligibility status, identifies which groups require approval, and perform single or bulk activations directly from the console.

## Features

- **Interactive Menu:** Easily select specific groups or activate all eligible groups at once.
- **Approval Detection:** Automatically identifies groups that require approval for activation.
- **Optional Approval Workflow:** By default, sensitive groups requiring approval are filtered out to prevent accidental requests, but they can be included using a specific parameter.
- **Automatic Duration Enforcement:** The script automatically checks the PIM policy for each group and adjusts your requested duration if it exceeds the maximum allowed by the organization (e.g., if you request 10 hours but a group allows only 4).
- **Portal Redirection:** Provides a direct link to the Microsoft Entra admin center for manual management.
- **Real-time Status:** Distinguishes between "Eligible" and "Already Active" assignments.
- **Automated Logging:** Detailed execution logs are saved with timestamps.
- **Results Export:** Final activation results are exported to a CSV file for auditing.
- **Cross-Platform:** Designed for PowerShell 7+.

## Interactive Menu Behavior

The script displays eligible groups in two sections:

1. **Selectable Groups:** These are groups you can activate immediately through the script. 
   - By default, this only includes groups that **do not** require approval.
   - If you use the `-IncludeApproveRequestGroup` parameter, groups requiring approval are added to this list.
2. **Approval Required (View Only):** If the script is run without the include parameter, these groups are displayed for visibility only. The script will provide a tip on how to enable activation for them.

## Prerequisites

### 1. PowerShell Version
- **PowerShell 7.x** (Core) is recommended for cross-platform compatibility.

### 2. Required Modules
The script requires the Microsoft Graph PowerShell SDK (Governance and SignIns modules).
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

### 3. Required Permissions
The script requests the following delegated scopes during interactive login:
- `PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup`
- `PrivilegedAssignmentSchedule.Read.AzureADGroup`
- `PrivilegedEligibilitySchedule.Read.AzureADGroup`
- `PrivilegedAccess.Read.AzureADGroup`
- `Directory.Read.All`
- `RoleManagement.Read.Directory` (Used to check PIM policy settings)
- `RoleManagementPolicy.Read.AzureADGroup` (Required to read PIM for Groups policies)

## Usage

### Syntax
```powershell
.\Invoke-PimGroupActivation.ps1 -Justification <String> [-Duration <String>] [-IncludeApproveRequestGroup]
```

### Parameters

| Parameter | Type | Required | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `Justification` | String | Yes | - | The business reason for the PIM activation. |
| `Duration` | String | No | `PT10H` | Activation duration in ISO 8601 format (e.g., `PT8H` for 8 hours). |
| `IncludeApproveRequestGroup` | Switch | No | `$false` | When set, allows the script to submit activation requests for groups that require approval. |

### Examples

**Standard Activation (No approval required):**
```powershell
.\Invoke-PimGroupActivation.ps1 -Justification "Routine maintenance"
```

**Full Activation (Including groups requiring approval):**
```powershell
.\Invoke-PimGroupActivation.ps1 -Justification "Emergency Fix" -IncludeApproveRequestGroup
```

## Policy Enforcement
To prevent "Bad Request" errors, the script performs a policy check for every group. If your requested `-Duration` (e.g., 10 hours) is longer than what the specific group policy allows (e.g., 4 hours for Global Admins), the script will automatically scale the request down to the maximum allowed limit and notify you in the log.

## Logging & Output

- **Logs:** Saved as `Invoke-PimGroupActivation_YYYYMMDD_HHMMSS.log` in the script directory.
- **Results:** Activation attempts and their statuses are exported to `Invoke-PimGroupActivation_Results_YYYYMMDD_HHMMSS.csv`.

## License
This project is for administrative use in Microsoft Entra ID environments. Use responsibly in accordance with your organization's security policies.
