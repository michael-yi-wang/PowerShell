# Invoke-AzureResourcePIM

Interactive PowerShell tool to list and activate eligible **Azure Resource PIM** (Privileged Identity Management) role assignments across Azure subscriptions.

## Overview

This script authenticates to Azure using a browser-based interactive login and scans all accessible subscriptions for eligible Azure RBAC PIM roles. It presents an interactive menu that lets you activate a single role or all eligible roles at once.

Unlike **PIM for Groups** (`Invoke-PimGroupActivation.ps1`), this script targets **Azure Resource PIM** — i.e., directly activating eligible Azure RBAC role assignments on subscriptions, resource groups, and individual resources.

## Prerequisites

| Requirement | Details |
|-------------|---------|
| PowerShell | 7.0 or later |
| Module | `Az.Accounts` — part of the [Az module](https://learn.microsoft.com/en-us/powershell/azure/install-azure-powershell) |
| Permissions | At least one eligible Azure RBAC PIM role in your tenant |
| PIM | Azure subscriptions must be [onboarded to PIM](https://learn.microsoft.com/en-us/azure/active-directory/privileged-identity-management/pim-resource-roles-discover-resources) |

### Install the Az module

```powershell
Install-Module Az -Scope CurrentUser -Force
```

## Authentication

The script uses `Connect-AzAccount` with the default interactive browser login, which supports:

- **FIDO2 security keys** (YubiKey, etc.)
- **Windows Hello for Business**
- **Microsoft Authenticator**
- **Standard MFA / Conditional Access**

> **Note:** Device code flow (`-UseDeviceAuthentication`) does **not** support FIDO2 keys. This script intentionally uses the browser popup to enable FIDO2.

## Parameters

| Parameter | Required | Default | Description |
|-----------|----------|---------|-------------|
| `-Justification` | Yes | — | Business reason for the activation, stored in the PIM audit log |
| `-Duration` | No | `PT8H` | ISO 8601 duration (e.g. `PT4H` = 4 hours, `PT30M` = 30 minutes). Capped by PIM policy. |
| `-SubscriptionId` | No | All accessible | One or more subscription GUIDs to limit the scan scope |
| `-TenantId` | No | Default tenant | Entra tenant ID, useful in multi-tenant environments |

## Usage

### Basic — activate a role interactively

```powershell
.\Invoke-AzureResourcePIM.ps1 -Justification "Investigating production incident"
```

### Limit to a specific subscription

```powershell
.\Invoke-AzureResourcePIM.ps1 -Justification "Deployment work" `
    -SubscriptionId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

### Multiple subscriptions with a custom duration

```powershell
.\Invoke-AzureResourcePIM.ps1 -Justification "Routine admin" -Duration "PT4H" `
    -SubscriptionId "sub-id-1", "sub-id-2"
```

### Specific tenant

```powershell
.\Invoke-AzureResourcePIM.ps1 -Justification "Cross-tenant access" `
    -TenantId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
```

## Interactive Menu

After login, the tool displays a table of all eligible assignments:

```
================================================================
         Azure Resource PIM Activation Tool
================================================================
Account  : user@contoso.com
Tenant   : xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx
Duration : PT8H

Eligible Azure Resource PIM Assignments:

# Role                         Scope                    Subscription         Status
- ----                         -----                    ------------         ------
1 Contributor                  Sub: Production          Production           Eligible
2 Reader                       RG: rg-webapp-prod       Production           Active
3 Key Vault Administrator       Resource: kv-prod        Production           Eligible

Options:
  [1-3]  Activate a specific role
  [A]    Activate ALL eligible (inactive) roles
  [R]    Refresh the list
  [Q]    Quit
```

- Select a **number** to activate a single role
- Enter **A** to activate all currently eligible (non-active) roles — confirmation is required
- Enter **R** to re-scan and refresh the list
- Enter **Q** to exit

## Output Files

Both files are saved to the same directory as the script with a `yyyyMMdd_HHmmss` timestamp suffix.

| File | Description |
|------|-------------|
| `Invoke-AzureResourcePIM_<timestamp>.log` | Full execution log with timestamps |
| `Invoke-AzureResourcePIM_Results_<timestamp>.csv` | CSV of all activation requests made in the session |

### CSV columns

| Column | Description |
|--------|-------------|
| Timestamp | Local time the request was submitted |
| RoleName | Friendly name of the Azure RBAC role |
| ScopeDisplay | Human-readable scope (subscription / resource group / resource) |
| Scope | Full ARM scope path |
| SubscriptionName | Subscription display name |
| SubscriptionId | Subscription GUID |
| Status | PIM provisioning status (`Provisioned`, `PendingApproval`, `Failed`, etc.) |
| Error | Error message if the activation request failed |

## Troubleshooting

| Symptom | Resolution |
|---------|-----------|
| No eligible assignments found | Ensure your account has eligible (not just active) PIM roles, and the subscriptions are onboarded to PIM |
| `Az.Accounts module not found` | Run `Install-Module Az -Scope CurrentUser` |
| Duration rejected | Your requested duration exceeds the policy maximum — use a shorter `-Duration` value |
| `HTTP 403` on activation | Your account may lack `Microsoft.Authorization/roleAssignmentScheduleRequests/write` at the target scope |
| Role name shows a GUID | The role definition lookup failed; the GUID is the role definition ID — check connectivity |

## Related Scripts

| Script | Purpose |
|--------|---------|
| [`Invoke-PimGroupActivation.ps1`](../Invoke-PimGroupActivation/) | Activate eligible **PIM for Groups** memberships (Entra group-level PIM) |
