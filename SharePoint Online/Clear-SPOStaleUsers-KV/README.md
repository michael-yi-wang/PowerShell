# Clear-SPOStaleUser (Key Vault variant) — Admin Setup Guide

## 1. Overview

`Clear-SPOStaleUser.ps1` removes stale user profiles from SharePoint Online site collections. This variant keeps the same interactive helpdesk menu as the original but replaces the local `config.json` approach with **Azure Key Vault secret retrieval**. No configuration file is required on helpdesk machines.

### How it works

```
Helpdesk machine
│
├─ 4 required + 1 optional environment variables (set by Intune / GPO)
│    SPO_APP_ID, SPO_TENANT_ID, SPO_KV_URL, SPO_CERT_THUMBPRINT
│    SPO_LA_WORKSPACE_ID  ← optional, enables Log Analytics remote logging
│
├─ Certificate (CurrentUser\My)  ─── silent SP auth ──►  Azure Key Vault
│                                                         ├─ spo-app-id
│                                                         ├─ spo-tenant-id
│                                                         ├─ spo-thumbprint
│                                                         └─ spo-la-workspace-key  (optional)
│
├─ Retrieved secrets ─── certificate auth ──►  SharePoint Online
│                                               (interactive menu)
│
└─ Log entries ──────────────────────────────►  Log Analytics workspace
                                                SPOStaleUser_CL table  (optional)
```

Key benefits:
- No sensitive values on disk.
- Certificate renewal is managed centrally in Key Vault — admin updates Key Vault first, then deploys the new cert via Intune at their own pace.
- All Key Vault secret access is audited in Azure Monitor.
- Optional Log Analytics integration centralises all helpdesk activity in one place for audit and alerting.

---

## 2. Prerequisites

- An **Azure subscription** with permission to create Key Vaults and role assignments.
- An **Entra ID app registration** (used for both SPO and Key Vault access).
- A **certificate** installed in the app registration and on each helpdesk machine (`CurrentUser\My`).
- Helpdesk machines running **Windows** (Intune-managed recommended for scale).
- PowerShell modules on each machine: `PnP.PowerShell`, `Az.Accounts`, `Az.KeyVault`.
- *(Optional)* An **Azure Log Analytics workspace** if you want centralised remote logging (see Section 5).

---

## 3. Step 1 — Entra ID App Registration

### 3a. Create the app registration

1. Open [Entra ID portal](https://entra.microsoft.com) > **App registrations** > **New registration**.
2. Give it a meaningful name (e.g., `SPO-HelpdeskApp`).
3. Leave **Redirect URI** empty (no user sign-in required).
4. Note down the **Application (Client) ID** and **Directory (Tenant) ID** shown on the Overview page.

### 3b. Generate the certificate

Run this on the machine where you want to create the certificate (or on your admin workstation):

```powershell
$cert = New-SelfSignedCertificate `
    -Subject 'CN=SPO-HelpdeskApp' `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -KeyExportPolicy Exportable `
    -KeySpec Signature `
    -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(2)

Write-Host "Thumbprint: $($cert.Thumbprint)"
```

Note down the thumbprint printed to the console.

### 3c. Upload the public key to the app registration

```powershell
# Export the public key (.cer — no private key)
Export-Certificate -Cert $cert -FilePath 'SPO-HelpdeskApp.cer' -Type CERT
```

In the Entra ID portal:

1. Open the app registration > **Certificates & secrets** > **Certificates** tab.
2. Click **Upload certificate**, browse to `SPO-HelpdeskApp.cer`, and upload it.

### 3d. Grant SharePoint API permission

1. In the app registration, go to **API permissions** > **Add a permission**.
2. Choose **SharePoint** > **Application permissions** > `Sites.FullControl.All`.
3. Click **Grant admin consent for \<your tenant\>**.

---

## 4. Step 2 — Azure Key Vault

### 4a. Create the Key Vault

```powershell
# Authenticate first
Connect-AzAccount

# Create a resource group if needed
New-AzResourceGroup -Name 'rg-spo-helpdesk' -Location 'australiaeast'

# Create the Key Vault with RBAC authorization model
New-AzKeyVault `
    -Name 'contoso-spo-kv' `
    -ResourceGroupName 'rg-spo-helpdesk' `
    -Location 'australiaeast' `
    -EnableRbacAuthorization $true
```

> **RBAC authorization model** is required. Do not use the legacy access-policy model.

### 4b. Store the secrets

**Required secrets (3):**

```powershell
Set-AzKeyVaultSecret `
    -VaultName 'contoso-spo-kv' `
    -Name 'spo-app-id' `
    -SecretValue (ConvertTo-SecureString '<Application Client ID>' -AsPlainText -Force)

Set-AzKeyVaultSecret `
    -VaultName 'contoso-spo-kv' `
    -Name 'spo-tenant-id' `
    -SecretValue (ConvertTo-SecureString '<Tenant ID or primary domain>' -AsPlainText -Force)

Set-AzKeyVaultSecret `
    -VaultName 'contoso-spo-kv' `
    -Name 'spo-thumbprint' `
    -SecretValue (ConvertTo-SecureString '<Certificate Thumbprint>' -AsPlainText -Force)
```

**Optional secret (Log Analytics — only required if `SPO_LA_WORKSPACE_ID` is set):**

```powershell
Set-AzKeyVaultSecret `
    -VaultName 'contoso-spo-kv' `
    -Name 'spo-la-workspace-key' `
    -SecretValue (ConvertTo-SecureString '<Log Analytics Primary or Secondary Key>' -AsPlainText -Force)
```

> Retrieve the workspace key from: **Log Analytics workspace** > **Settings** > **Agents** > **Log Analytics agent instructions** > **Primary key**.

### 4c. Grant the service principal access to Key Vault

The app registration's service principal needs the **Key Vault Secrets User** role on the Key Vault:

```powershell
New-AzRoleAssignment `
    -ApplicationId '<Application Client ID>' `
    -RoleDefinitionName 'Key Vault Secrets User' `
    -Scope '/subscriptions/<SubscriptionId>/resourceGroups/rg-spo-helpdesk/providers/Microsoft.KeyVault/vaults/contoso-spo-kv'
```

Verify the assignment:

```powershell
Get-AzRoleAssignment `
    -Scope '/subscriptions/<SubscriptionId>/resourceGroups/rg-spo-helpdesk/providers/Microsoft.KeyVault/vaults/contoso-spo-kv' |
    Where-Object { $_.DisplayName -match 'SPO-HelpdeskApp' }
```

---

## 5. Step 2b — Log Analytics Workspace (Optional)

Configuring a Log Analytics workspace enables centralised, queryable audit logs for all helpdesk sessions across every machine. When enabled, each `Write-Log` call in the script sends an entry to the **`SPOStaleUser_CL`** custom table in addition to the local log file.

> **This section is entirely optional.** Skip it if local file logs are sufficient.

### 5a. Create a Log Analytics workspace

```powershell
# Use an existing resource group or create one
New-AzResourceGroup -Name 'rg-spo-helpdesk' -Location 'australiaeast'

New-AzOperationalInsightsWorkspace `
    -ResourceGroupName 'rg-spo-helpdesk' `
    -Name 'law-spo-helpdesk' `
    -Location 'australiaeast' `
    -Sku 'PerGB2018'
```

### 5b. Retrieve the Workspace ID and key

```powershell
$workspace = Get-AzOperationalInsightsWorkspace `
    -ResourceGroupName 'rg-spo-helpdesk' `
    -Name 'law-spo-helpdesk'

# Workspace ID — goes into the SPO_LA_WORKSPACE_ID environment variable
$workspace.CustomerId

# Primary key — goes into the 'spo-la-workspace-key' Key Vault secret
(Get-AzOperationalInsightsWorkspaceSharedKey `
    -ResourceGroupName 'rg-spo-helpdesk' `
    -Name 'law-spo-helpdesk').PrimarySharedKey
```

Alternatively, retrieve the values from the Azure portal:
**Log Analytics workspace** > **Settings** > **Agents** > **Log Analytics agent instructions**.

### 5c. Store the workspace key in Key Vault

```powershell
$laKey = (Get-AzOperationalInsightsWorkspaceSharedKey `
    -ResourceGroupName 'rg-spo-helpdesk' `
    -Name 'law-spo-helpdesk').PrimarySharedKey

Set-AzKeyVaultSecret `
    -VaultName 'contoso-spo-kv' `
    -Name 'spo-la-workspace-key' `
    -SecretValue (ConvertTo-SecureString $laKey -AsPlainText -Force)
```

### 5d. Set the environment variable via Intune

Add `SPO_LA_WORKSPACE_ID` to the same Intune Configuration Profile that delivers the other four environment variables:

| Variable | Value |
|----------|-------|
| `SPO_LA_WORKSPACE_ID` | GUID shown in `$workspace.CustomerId` |

Once the policy syncs, the script will forward all log entries to the `SPOStaleUser_CL` table.

### 5e. Query logs in Log Analytics

After at least one script run, the custom table will be available. Example KQL queries:

```kql
// All activity from the last 7 days
SPOStaleUser_CL
| where TimeGenerated >= ago(7d)
| project TimeGenerated, Level_s, Message_s, Computer_s, UserName_s
| order by TimeGenerated desc

// Removal events only
SPOStaleUser_CL
| where Message_s has "Removed user"
| project TimeGenerated, Computer_s, UserName_s, Message_s

// Errors and warnings
SPOStaleUser_CL
| where Level_s in ("Error", "Warning")
| project TimeGenerated, Level_s, Message_s, Computer_s
```

> **Note:** The `SPOStaleUser_CL` table is created automatically on the first log ingestion. Allow up to 15 minutes for the table and first entries to appear after the initial run.

---

## 6. Step 3 — Helpdesk Machine Setup

### 5a. Install the Certificate

**Option A — Manual (test / small scale)**

Export the PFX from the machine where the certificate was created:

```powershell
$cert = Get-Item "Cert:\CurrentUser\My\<Thumbprint>"
Export-PfxCertificate `
    -Cert $cert `
    -FilePath 'spo-helpdesk-app.pfx' `
    -Password (Read-Host -AsSecureString 'PFX password')
```

Import on each target machine:

```powershell
Import-PfxCertificate `
    -FilePath 'spo-helpdesk-app.pfx' `
    -CertStoreLocation 'Cert:\CurrentUser\My' `
    -Password (Read-Host -AsSecureString 'PFX password')
```

**Option B — Intune (recommended for scale)**

Deploy the certificate via an Intune **PKCS** or **SCEP** certificate profile targeting the helpdesk user group. Set the certificate store to **User** (`CurrentUser\My`).

### 5b. Install Required PowerShell Modules

Run on each helpdesk machine (or deploy via Intune PowerShell script):

```powershell
Install-Module -Name PnP.PowerShell -Scope CurrentUser -Force
Install-Module -Name Az.Accounts    -Scope CurrentUser -Force
Install-Module -Name Az.KeyVault    -Scope CurrentUser -Force
```

For Intune-scale deployment, package these commands into an Intune **PowerShell script** deployment or a Win32 app package.

### 5c. Set Environment Variables via Intune

Configure the following **machine-scope** environment variables using Intune:

- **Recommended method**: Configuration Profile > Settings Catalog > search for "Environment Variables" (Windows).
- **Alternative**: Custom OMA-URI policy (see below).

| Variable | Required | Value |
|----------|----------|-------|
| `SPO_APP_ID` | Yes | Application (Client) ID of the Entra ID app registration |
| `SPO_TENANT_ID` | Yes | Tenant ID (GUID) or primary domain (e.g. `contoso.onmicrosoft.com`) |
| `SPO_KV_URL` | Yes | `https://contoso-spo-kv.vault.azure.net` |
| `SPO_CERT_THUMBPRINT` | Yes | SHA1 thumbprint of the installed certificate |
| `SPO_LA_WORKSPACE_ID` | No | Workspace ID (GUID) from the Log Analytics workspace. When present, enables remote logging to the `SPOStaleUser_CL` table. Requires the `spo-la-workspace-key` secret in Key Vault. |

**Custom OMA-URI example** (for one variable; repeat for each):

| Field | Value |
|-------|-------|
| OMA-URI | `./Device/Vendor/MSFT/EnterpriseDesktopAppManagement/MSI/EnvironmentVariables/SPO_APP_ID` |
| Data type | `String` |
| Value | `<Application Client ID>` |

> Note: Machine-scope environment variables require a reboot or sign-out/sign-in to take effect.

Verify on any managed machine:

```powershell
$env:SPO_APP_ID
$env:SPO_TENANT_ID
$env:SPO_KV_URL
$env:SPO_CERT_THUMBPRINT
```

---

## 7. Certificate Renewal Procedure

Follow these steps in order to renew the certificate without interrupting helpdesk operations:

1. **Generate the new certificate** on your admin workstation (same `New-SelfSignedCertificate` command as Step 1). Note the new thumbprint.

2. **Upload the new `.cer`** to the Entra ID app registration (**do NOT remove the old certificate yet** — leave both active during the transition).

3. **Update the `spo-thumbprint` secret in Key Vault** to the new thumbprint value:

    ```powershell
    Set-AzKeyVaultSecret `
        -VaultName 'contoso-spo-kv' `
        -Name 'spo-thumbprint' `
        -SecretValue (ConvertTo-SecureString '<New Thumbprint>' -AsPlainText -Force)
    ```

    From this point, the script will emit a **thumbprint mismatch warning** on machines that still have the old certificate — this is expected and the script will continue functioning normally using the old cert.

4. **Deploy the new certificate** to helpdesk machines via Intune (PKCS/SCEP profile or PFX script deployment).

5. **Update the `SPO_CERT_THUMBPRINT` environment variable** via Intune policy to the new thumbprint value. Apply and sync the policy.

6. **Verify** a sample machine has received both the new certificate and the updated environment variable:

    ```powershell
    Get-ChildItem Cert:\CurrentUser\My | Where-Object { $_.Subject -like '*SPO-HelpdeskApp*' }
    $env:SPO_CERT_THUMBPRINT
    ```

7. **Remove the old certificate** from the Entra ID app registration only after confirming all machines have the new cert and the mismatch warning is no longer appearing in logs.

---

## 8. Helpdesk Usage

No parameters are needed. Simply run:

```powershell
.\Clear-SPOStaleUser.ps1
```

The script will:
1. Check module availability (`Az.Accounts`, `Az.KeyVault`, `PnP.PowerShell`).
2. Read the four environment variables.
3. Authenticate silently to Azure Key Vault using the installed certificate.
4. Retrieve the three connection secrets from Key Vault.
5. Launch the interactive menu.

**Interactive menu options:**

| Key | Action |
|-----|--------|
| `S` | Set the SharePoint Online site collection URL |
| `U` | Set the user UPN to look up |
| `C` | Check for a stale profile and optionally remove it |
| `Q` | Quit the script |

---

## 9. Security Notes

- The **four environment variables are not secrets** — they are public identifiers (GUIDs, domain names, URLs, and a certificate thumbprint). They carry no risk if observed.
- The **only sensitive asset is the certificate private key**, which is protected by the Windows certificate store using OS-level ACLs. Only the certificate owner (the logged-in user) can use it.
- **Azure Key Vault** provides the authoritative source of truth for all connection values. Access to secrets is controlled by RBAC and fully audited.
- All Key Vault secret reads are logged in **Azure Monitor / Key Vault diagnostic logs** — enable these in the Key Vault's Diagnostic settings and route to a Log Analytics workspace.
- The script writes a **local log file** to the `logs\` subfolder next to the script for each session. Logs contain no secret values — only operational events.
- When Log Analytics is enabled, logs are forwarded over HTTPS using an HMAC-SHA256 shared key signature. The workspace key is retrieved at runtime from Key Vault and held in memory only for the duration of the session — it is never written to disk.
- The certificate used for authentication has no browser-based OAuth flow, eliminating the risk of token theft via phishing.

---

## 10. Troubleshooting

| Symptom | Likely cause | Fix |
|---------|-------------|-----|
| "Environment variable not set" | Intune policy not yet applied or machine not synced | Run `Start-Process -FilePath 'deviceenroller.exe' -ArgumentList '/o'` or reboot; verify variables with `$env:SPO_APP_ID` |
| "Certificate not found in CurrentUser\My" | Certificate not deployed to this machine, or thumbprint in env var is wrong | Run `Get-ChildItem Cert:\CurrentUser\My`; check Intune certificate profile assignment |
| "Azure authentication failed" | App registration not granted `Key Vault Secrets User` role on Key Vault, or cert is expired | Check role assignment with `Get-AzRoleAssignment`; check cert expiry with `Get-Item "Cert:\CurrentUser\My\<thumbprint>"` |
| "Could not retrieve secret 'spo-app-id'" | Admin has not created the KV secrets yet | Follow Section 4b to create all three secrets |
| "Could not retrieve secret 'spo-thumbprint'" | Same as above, or secret was accidentally deleted | Re-create the secret in Key Vault |
| Thumbprint mismatch warning appears | Certificate renewal is in progress (expected) | Wait for Intune to deliver updated cert and env var; no action required from helpdesk |
| "Connection failed to SPO" | App registration missing `Sites.FullControl.All` permission, or cert mismatch | Verify API permission and admin consent in Entra ID portal; confirm KV thumbprint matches deployed cert |
| Script exits immediately with no menu | Module check failed | Run `Install-Module -Name Az.Accounts -Scope CurrentUser -Force` etc. as directed by the on-screen message |
| Log Analytics warning: "key not found in Key Vault" | `SPO_LA_WORKSPACE_ID` env var is set but `spo-la-workspace-key` secret was not created in Key Vault | Follow Section 5c to store the workspace key, or remove `SPO_LA_WORKSPACE_ID` to disable remote logging |
| `SPOStaleUser_CL` table missing in Log Analytics | Table is created on first ingestion and can take up to 15 minutes to appear | Wait 15 minutes and re-run; verify `SPO_LA_WORKSPACE_ID` is correct and `spo-la-workspace-key` is valid |
