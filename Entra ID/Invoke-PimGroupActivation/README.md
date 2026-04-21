# Invoke-PimGroupActivation

An interactive PowerShell script to manage and activate **Microsoft Entra ID Privileged Identity Management (PIM) for Groups** assignments.

## Overview

`Invoke-PimGroupActivation.ps1` simplifies the process of activating eligible group assignments. It provides an interactive menu that allows users to view their current eligibility status, identifies which groups require approval, and perform single or bulk activations for groups that do not require approval directly from the console.

## Features

- **Interactive Menu:** Easily select specific groups or activate all eligible groups (that don't require approval) at once.
- **Approval Detection:** Automatically identifies groups that require approval for activation.
- **Security Logic:** To maintain security integrity, groups requiring approval (typically high-privilege groups like Global Admins) are restricted from direct activation within the script.
- **Portal Redirection:** Provides instructions and a direct link to the Azure Portal for groups requiring approval.
- **Real-time Status:** Distinguishes between "Eligible" and "Already Active" assignments.
- **Automated Logging:** Detailed execution logs are saved with timestamps.
- **Results Export:** Final activation results are exported to a CSV file for auditing.
- **Cross-Platform:** Designed for PowerShell 7+.

## Interactive Menu Behavior

The script categorizes eligible groups into two sections:

1. **Direct Activation:** These groups do not require approval. You can activate them individually by index or all at once using the `[A]` option.
2. **Approval Required:** These groups require an approval workflow. Because these often involve sensitive permissions, the script redirects you to the Microsoft Entra admin center to initiate the request, ensuring the full security context and approver notifications are handled correctly by the platform.

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
.\Invoke-PimGroupActivation.ps1 -Justification <String> [-Duration <String>]
```

### Parameters

| Parameter | Type | Required | Default | Description |
| :--- | :--- | :--- | :--- | :--- |
| `Justification` | String | Yes | - | The business reason for the PIM activation. |
| `Duration` | String | No | `PT10H` | Activation duration in ISO 8601 format (e.g., `PT8H` for 8 hours). |

### Example
Activate groups for a system maintenance window:
```powershell
.\Invoke-PimGroupActivation.ps1 -Justification "Monthly System Maintenance" -Duration "PT4H"
```

## Logging & Output

- **Logs:** Saved as `Invoke-PimGroupActivation_YYYYMMDD_HHMMSS.log` in the script directory.
- **Results:** Activation attempts and their statuses are exported to `Invoke-PimGroupActivation_Results_YYYYMMDD_HHMMSS.csv`.

## License
This project is for administrative use in Microsoft Entra ID environments. Use responsibly in accordance with your organization's security policies.
