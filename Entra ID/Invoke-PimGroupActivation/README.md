# Invoke-PimGroupActivation

An interactive PowerShell script to manage and activate **Microsoft Entra ID Privileged Identity Management (PIM) for Groups** assignments.

## Overview

`Invoke-PimGroupActivation.ps1` simplifies the process of activating eligible group assignments. It provides an interactive menu that allows users to view their current eligibility status, identify which groups require approval, and perform single or bulk activations directly from the console.

## Features

- **Interactive Menu:** Select a specific group by index, activate all eligible groups at once, or refresh the list.
- **Bulk Activation with Confirmation:** Activating all eligible groups requires an explicit confirmation prompt to prevent accidental bulk requests.
- **Approval Detection:** Automatically identifies groups that require approval for activation and separates them into a dedicated non-selectable section with guidance.
- **Optional Approval Workflow:** By default, groups requiring approval are filtered out; they can be included using `-IncludeApproveRequestGroup`.
- **Automatic Duration Enforcement:** Checks the PIM policy for each group and caps the requested duration to the maximum allowed by the organization.
- **Performance Optimization:** Group display names are fetched in a single batched pass before building the menu, avoiding redundant API calls per group.
- **Progress Indicators:** Progress bars are shown while loading group information and checking PIM policies.
- **Real-time Status:** Distinguishes between `Eligible` and `Already Active` assignments on every refresh.
- **Automated Logging:** Detailed execution logs are saved with timestamps in the script directory.
- **Results Export:** Final activation results are exported to a CSV file for auditing.
- **Cross-Platform:** Requires PowerShell 7.0+ for cross-platform compatibility.

## Interactive Menu Behavior

The script displays eligible groups in two sections:

1. **Selectable Groups:** Groups you can activate through the script.
   - By default, only includes groups that **do not** require approval.
   - With `-IncludeApproveRequestGroup`, approval-gated groups are added to this list. Their requests will remain pending until an approver acts.
2. **Approval Required (View Only):** Groups requiring approval are shown separately when the parameter is not specified, along with a tip on how to include them.

## Prerequisites

### 1. PowerShell Version
- **PowerShell 7.0+** is required.

### 2. Required Modules
The script requires the Microsoft Graph PowerShell SDK.
```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

### 3. Required Permissions
The following delegated scopes are requested during interactive login:

| Scope | Purpose |
| :--- | :--- |
| `PrivilegedAssignmentSchedule.ReadWrite.AzureADGroup` | Submit PIM activation requests |
| `PrivilegedAssignmentSchedule.Read.AzureADGroup` | Read active group assignments |
| `PrivilegedEligibilitySchedule.Read.AzureADGroup` | Read eligible group assignments |
| `PrivilegedAccess.Read.AzureADGroup` | Read PIM for Groups data |
| `Directory.Read.All` | Resolve group display names |
| `RoleManagement.Read.Directory` | Read PIM policy settings |
| `RoleManagementPolicy.Read.AzureADGroup` | Read PIM for Groups policies (approval and duration rules) |

## Usage

### Syntax
```powershell
.\Invoke-PimGroupActivation.ps1 -Justification <String> [-Duration <String>] [-IncludeApproveRequestGroup]
```

### Parameters

| Parameter | Type | Required | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `Justification` | String | Yes | — | The business reason for the PIM activation. |
| `Duration` | String | No | `PT10H` | Activation duration in ISO 8601 format (e.g., `PT8H` for 8 hours). |
| `IncludeApproveRequestGroup` | Switch | No | — | When specified, allows the script to submit activation requests for groups that require approval. |

### Examples

**Standard activation (approval-required groups excluded):**
```powershell
.\Invoke-PimGroupActivation.ps1 -Justification "Routine maintenance"
```

**Include groups requiring approval:**
```powershell
.\Invoke-PimGroupActivation.ps1 -Justification "Emergency fix" -IncludeApproveRequestGroup
```

**Custom duration:**
```powershell
.\Invoke-PimGroupActivation.ps1 -Justification "System administration" -Duration "PT4H"
```

## Policy Enforcement

For every group, the script queries the PIM assignment policy to retrieve the maximum allowed activation duration. If your requested `-Duration` exceeds what the policy permits, the request is automatically capped to the allowed maximum and a warning is written to the log.

## Logging and Output

| File | Naming Pattern | Description |
| :--- | :--- | :--- |
| Log | `Invoke-PimGroupActivation_YYYYMMDD_HHMMSS.log` | Full execution log with timestamps and log levels |
| Results | `Invoke-PimGroupActivation_Results_YYYYMMDD_HHMMSS.csv` | Activation results (group, access type, status, error) |

Both files are saved in the same directory as the script.

## License
This project is for administrative use in Microsoft Entra ID environments. Use responsibly in accordance with your organization's security policies.
