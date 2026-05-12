# Clear-SPOStaleUsers-CICD — Admin Setup Guide

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Step 1 — Entra ID App Registration](#3-step-1--entra-id-app-registration)
4. [Step 2 — Azure Key Vault](#4-step-2--azure-key-vault)
5. [Step 3 — Azure DevOps Setup](#5-step-3--azure-devops-setup)
6. [Step 4 — Helpdesk Machine Setup](#6-step-4--helpdesk-machine-setup)
7. [Certificate Renewal Procedure](#7-certificate-renewal-procedure)
8. [Helpdesk Usage](#8-helpdesk-usage)
9. [Troubleshooting](#9-troubleshooting)

---

## 1. Overview

This toolset provides a controlled, auditable workflow for removing stale user profiles from SharePoint Online (SPO) site collections. All changes require an IT manager approval before execution.

### Architecture

```
Helpdesk Operator
       |
       | runs Invoke-SPOPipeline.ps1
       | (enters site URL and user UPN at prompt)
       |
       v
Azure DevOps REST API
       |
       v
+-------------------------------+
| pipeline.yml                  |
|                               |
| Stage 1 — CheckUser           |
|   Clear-SPOStaleUser.ps1      |
|   -CheckOnly                  |
|   (read-only, no changes)     |
|                               |
|   >> output visible in ADO    |
+-------------------------------+
       |
       | Pipeline pauses — approval email sent to IT manager
       |
       v
IT Manager reviews Stage 1 output in ADO and approves (or rejects)
       |
       v
+-------------------------------+
| Stage 2 — RemoveUser          |
|   Clear-SPOStaleUser.ps1      |
|   -Force                      |
|   (permanent removal)         |
+-------------------------------+
       |
       v
User removed from SPO site — full audit trail in ADO logs
```

### Key design decisions

- **No secrets on helpdesk machines.** The ADO PAT has only `Build: Queue` scope; it cannot read Key Vault values or pipeline secrets.
- **Certificate-based app-only auth.** The Entra ID app uses a certificate (not a client secret) stored as an ADO Secure File and never leaves the pipeline agent.
- **Approval gate.** Stage 2 runs only after an authorised approver clicks Approve in Azure DevOps. ADO logs the approver identity and timestamp permanently.
- **CheckOnly output as evidence.** Stage 1 produces the user profile in the pipeline log before any removal decision is made.

---

## 2. Prerequisites

Before starting, ensure the following are available:

- An **Azure subscription** with permission to create an Azure Key Vault
- An **Entra ID (Azure AD) tenant** with Global Administrator or Application Administrator access to create an app registration
- An **Azure DevOps organisation and project** (any tier, including the free tier)
- **PowerShell 7.0+** installed on the administrator's workstation for certificate generation steps
- The **PnP.PowerShell** module installed on the administrator's workstation for testing

---

## 3. Step 1 — Entra ID App Registration

### 3a. Create the app registration

1. Open the [Azure Portal](https://portal.azure.com) and navigate to **Entra ID > App registrations > New registration**.
2. Set a descriptive name, for example: `SPO-Helpdesk-StaleUser-App`.
3. Set **Supported account types** to *Accounts in this organizational directory only*.
4. Leave **Redirect URI** blank.
5. Click **Register**.
6. Copy the **Application (client) ID** and **Directory (tenant) ID** — you will need both later.

### 3b. Grant API permissions

1. In the app registration, go to **API permissions > Add a permission**.
2. Select **SharePoint**.
3. Select **Application permissions**.
4. Search for and enable `Sites.FullControl.All`.
5. Click **Add permissions**.
6. Click **Grant admin consent for \<your tenant\>** and confirm.

The permissions tab should now show `Sites.FullControl.All` with status **Granted**.

### 3c. Generate a self-signed certificate

Run the following on a Windows workstation (PowerShell 5.1 or 7.0):

```powershell
$certParams = @{
    Subject           = 'CN=SPO-Helpdesk-App'
    CertStoreLocation = 'Cert:\CurrentUser\My'
    KeyExportPolicy   = 'Exportable'
    KeySpec           = 'Signature'
    NotAfter          = (Get-Date).AddYears(2)
    HashAlgorithm     = 'SHA256'
}
$cert = New-SelfSignedCertificate @certParams
Write-Host "Thumbprint: $($cert.Thumbprint)"
```

Note the thumbprint output — you will need it in Key Vault.

### 3d. Export the certificate

Export the **public key** (.cer) for upload to Entra ID:

```powershell
$cerPath = "$env:TEMP\spo-helpdesk-app.cer"
Export-Certificate -Cert $cert -FilePath $cerPath -Type CERT | Out-Null
Write-Host "Public cert exported to: $cerPath"
```

Export the **private key** (.pfx) for upload to ADO Secure Files:

```powershell
$pfxPath = "$env:TEMP\spo-helpdesk-app.pfx"
$pfxPassword = Read-Host -AsSecureString 'Enter a strong PFX password'
Export-PfxCertificate -Cert $cert -FilePath $pfxPath -Password $pfxPassword | Out-Null
Write-Host "PFX exported to: $pfxPath"
```

Store the PFX password securely — you will save it as the `spo-cert-password` secret in Key Vault.

### 3e. Upload the public certificate to the app registration

1. In the app registration, go to **Certificates & secrets > Certificates > Upload certificate**.
2. Select the `.cer` file exported in step 3d.
3. Click **Add**.

The certificate is now associated with the app registration.

---

## 4. Step 2 — Azure Key Vault

### 4a. Create a Key Vault

```powershell
# Adjust resource group, location, and vault name as appropriate.
az keyvault create `
    --name       "kv-spo-helpdesk" `
    --resource-group "rg-it-operations" `
    --location   "australiaeast" `
    --sku        standard
```

### 4b. Store the four secrets

```powershell
$vaultName = "kv-spo-helpdesk"

# Application (client) ID from the app registration.
az keyvault secret set --vault-name $vaultName --name "spo-app-id"      --value "<app-client-id>"

# Entra ID tenant ID or primary domain.
az keyvault secret set --vault-name $vaultName --name "spo-tenant-id"   --value "<tenant-id-or-domain>"

# Certificate thumbprint (SHA1, no spaces).
az keyvault secret set --vault-name $vaultName --name "spo-thumbprint"  --value "<certificate-thumbprint>"

# PFX export password chosen in step 3d.
az keyvault secret set --vault-name $vaultName --name "spo-cert-password" --value "<pfx-password>"
```

### 4c. Grant the ADO service connection access to Key Vault

The ADO variable group (configured in the next step) requires read access to Key Vault secrets. The service principal used by the ADO service connection must hold the **Key Vault Secrets User** role:

```powershell
# Replace <service-principal-object-id> with the Object ID of the ADO service principal.
az role assignment create `
    --assignee   "<service-principal-object-id>" `
    --role       "Key Vault Secrets User" `
    --scope      "/subscriptions/<subscription-id>/resourceGroups/rg-it-operations/providers/Microsoft.KeyVault/vaults/kv-spo-helpdesk"
```

---

## 5. Step 3 — Azure DevOps Setup

### 5a. Variable Group

1. In your ADO project, go to **Pipelines > Library > Variable groups > + Variable group**.
2. Name the group exactly: `SPO-Helpdesk-Secrets`.
3. Enable the **Link secrets from an Azure key vault as variables** toggle.
4. Select your Azure subscription and the Key Vault created in Step 2.
5. Click **+ Add** and map the following variables:

   | Variable group variable | Key Vault secret     |
   |------------------------|----------------------|
   | `AppId`                | `spo-app-id`         |
   | `TenantId`             | `spo-tenant-id`      |
   | `Thumbprint`           | `spo-thumbprint`     |
   | `CertPassword`         | `spo-cert-password`  |

6. Click **Save**.
7. Go to the variable group's **Pipeline permissions** tab and authorise it for the target pipeline (or set it to allow all pipelines in the project).

### 5b. Secure Files

1. Go to **Pipelines > Library > Secure files > + Secure file**.
2. Upload the `spo-helpdesk-app.pfx` file exported in step 3d.
3. Ensure the file is named exactly `spo-helpdesk-app.pfx` (this name is referenced in `pipeline.yml`).
4. After upload, click the file name, go to **Pipeline permissions**, and authorise access for the target pipeline.

### 5c. Import the Pipeline

1. Commit all four files in this folder to the ADO git repository at the path:
   ```
   SharePoint Online/Clear-SPOStaleUsers-CICD/
   ```
2. In ADO, go to **Pipelines > New pipeline**.
3. Select **Azure Repos Git** > select your repository.
4. Select **Existing Azure Pipelines YAML file**.
5. Set the path to:
   ```
   SharePoint Online/Clear-SPOStaleUsers-CICD/pipeline.yml
   ```
6. Click **Continue**, then **Save** (do not run yet).
7. Note the **pipeline ID** from the browser URL bar — it appears as a number after `definitionId=` or in the URL path. You will need this for the helpdesk machine setup.

### 5d. Create the Approval Environment

1. Go to **Pipelines > Environments > New environment**.
2. Name the environment exactly: `SPO-Helpdesk-Approval`.
3. Set **Resource** to *None*.
4. Click **Create**.
5. Open the environment, click the `...` menu, and select **Approvals and checks**.
6. Click **+** and select **Approvals**.
7. Add the approver(s) — for example, the IT helpdesk manager's ADO account.
8. Set a **Timeout** (recommended: 24 hours) and optionally add approval instructions such as:
   > Review the Stage 1 log to confirm the correct user and site before approving.
9. Click **Create**.

The pipeline will pause between Stage 1 and Stage 2 and send an email notification to the approver.

---

## 6. Step 4 — Helpdesk Machine Setup

### 6a. Copy the wrapper script

Copy `Invoke-SPOPipeline.ps1` to a shared path on the helpdesk machine, for example:

```
C:\IT-Tools\SPO\Invoke-SPOPipeline.ps1
```

Ensure PowerShell 7.0+ (`pwsh`) is installed on the machine.

### 6b. Set environment variables via Intune

Configure the following four **machine-scope** environment variables using an Intune Configuration Profile (Settings Catalog > Windows > Environment Variables, or a Custom OMA-URI profile):

| Variable          | Value                                        |
|-------------------|----------------------------------------------|
| `ADO_ORG_URL`     | `https://dev.azure.com/contoso`              |
| `ADO_PROJECT`     | `IT-Operations`                              |
| `ADO_PIPELINE_ID` | The integer pipeline ID from step 5c         |
| `ADO_PAT`         | PAT for the helpdesk service account (below) |

#### Creating the PAT

1. Log in to ADO as the **helpdesk service account** (a dedicated non-personal account).
2. Go to **User settings > Personal access tokens > New Token**.
3. Set the name to `SPO-Helpdesk-Pipeline-Trigger`.
4. Set **Organisation** to your ADO organisation.
5. Set **Expiration** to 90 days (or your organisation's policy).
6. Under **Scopes**, select **Custom defined** and enable only:
   - **Build: Read & execute** (under the Build category)
7. Click **Create** and copy the token value immediately — it is shown only once.
8. Store the token value as the `ADO_PAT` environment variable.

#### Verify environment variables are set correctly

Run the following in an elevated PowerShell session on the machine after Intune syncs:

```powershell
[System.Environment]::GetEnvironmentVariables('Machine') |
    Where-Object { $_.Key -in @('ADO_ORG_URL','ADO_PROJECT','ADO_PIPELINE_ID','ADO_PAT') }
```

All four variables should appear with their configured values.

---

## 7. Certificate Renewal Procedure

Certificates should be renewed before their expiry date. Follow these steps in order to avoid service interruption.

**1. Generate a new certificate on the administrator's workstation:**

```powershell
$newCertParams = @{
    Subject           = 'CN=SPO-Helpdesk-App'
    CertStoreLocation = 'Cert:\CurrentUser\My'
    KeyExportPolicy   = 'Exportable'
    KeySpec           = 'Signature'
    NotAfter          = (Get-Date).AddYears(2)
    HashAlgorithm     = 'SHA256'
}
$newCert = New-SelfSignedCertificate @newCertParams
Write-Host "New thumbprint: $($newCert.Thumbprint)"
```

**2. Export the new public cert (.cer) and upload to the Entra ID app registration:**

```powershell
$newCerPath = "$env:TEMP\spo-helpdesk-app-new.cer"
Export-Certificate -Cert $newCert -FilePath $newCerPath -Type CERT | Out-Null
```

In the Entra ID portal, navigate to the app registration > **Certificates & secrets > Certificates > Upload certificate**. Upload the new `.cer` file. Keep the old certificate active during transition — do not delete it yet.

**3. Export the new private key (.pfx):**

```powershell
$newPfxPath  = "$env:TEMP\spo-helpdesk-app-new.pfx"
$newPassword = Read-Host -AsSecureString 'Enter new PFX password'
Export-PfxCertificate -Cert $newCert -FilePath $newPfxPath -Password $newPassword | Out-Null
```

**4. Update Key Vault secrets:**

```powershell
$vaultName = "kv-spo-helpdesk"

# Update thumbprint to the new certificate's thumbprint.
az keyvault secret set --vault-name $vaultName --name "spo-thumbprint"    --value "<new-thumbprint>"

# Update cert password if the new PFX uses a different password.
az keyvault secret set --vault-name $vaultName --name "spo-cert-password" --value "<new-pfx-password>"
```

**5. Replace the Secure File in ADO Library:**

1. Go to **Pipelines > Library > Secure files**.
2. Delete the existing `spo-helpdesk-app.pfx`.
3. Upload the new PFX file with the same name: `spo-helpdesk-app.pfx`.
4. Re-authorise pipeline access on the secure file if prompted.

**6. Run a test pipeline** with `-CheckOnly` to confirm the new certificate authenticates correctly.

**7. Remove the old certificate from the Entra ID app registration:**

Navigate to the app registration > **Certificates & secrets > Certificates**, find the old certificate (by its old thumbprint or expiry date), and delete it.

**8. No changes are required on helpdesk machines.** The `ADO_PAT` and the four env vars remain unchanged.

---

## 8. Helpdesk Usage

Ensure PowerShell 7.0+ is used (run from the `pwsh` executable):

```powershell
pwsh -File "C:\IT-Tools\SPO\Invoke-SPOPipeline.ps1"
```

Or, if the execution policy allows, simply:

```powershell
.\Invoke-SPOPipeline.ps1
```

The script will:

1. Print a banner and check all environment variables.
2. Prompt for the **SharePoint site URL** (with format guidance).
3. Prompt for the **user UPN** to inspect or remove.
4. Queue the pipeline and print the pipeline run URL.
5. Offer to open the pipeline URL in the default browser.

The IT manager will receive an email asking them to approve Stage 2. The helpdesk operator can monitor progress at the pipeline URL.

---

## 9. Troubleshooting

### PAT expired

**Symptom:** `Invoke-SPOPipeline.ps1` fails with HTTP 401 Unauthorized.

**Fix:**
1. Log in to ADO as the helpdesk service account.
2. Create a new PAT with **Build: Read & execute** scope.
3. Update the `ADO_PAT` machine environment variable on all helpdesk machines via Intune.
4. Allow Intune to sync (or run a manual sync on the device).

### "Pipeline not found" / HTTP 404

**Symptom:** `Invoke-SPOPipeline.ps1` fails with HTTP 404.

**Fix:**
- Verify `ADO_PIPELINE_ID` contains the correct integer pipeline ID.
- Verify `ADO_PROJECT` matches the project name exactly (case-sensitive).
- Verify `ADO_ORG_URL` is in the format `https://dev.azure.com/<org>` with no trailing slash issues (the script normalises trailing slashes, but confirm the value is correct).

### "Certificate not found" in pipeline

**Symptom:** The `Install certificate` step fails, or `Connect-PnPOnline` throws a certificate-not-found error.

**Fix:**
- Confirm the PFX file in **Pipelines > Library > Secure files** is named exactly `spo-helpdesk-app.pfx`.
- Confirm the `CertPassword` variable in the variable group matches the actual PFX password in Key Vault.
- Confirm the secure file is authorised for the pipeline (check Pipeline permissions on the secure file).

### "Connection failed to SPO" in pipeline

**Symptom:** `Clear-SPOStaleUser.ps1` logs a connection error.

**Fix:**
- Confirm the `Thumbprint` secret in Key Vault matches the certificate currently uploaded to the Entra ID app registration.
- Confirm `Sites.FullControl.All` application permission has admin consent granted on the app registration.
- Confirm the `AppId` secret in Key Vault matches the app registration's Application (client) ID.
- Check whether the Entra ID app registration's certificate has expired. If so, follow the [Certificate Renewal Procedure](#7-certificate-renewal-procedure).

### Variable group / Key Vault access denied

**Symptom:** Pipeline fails at variable group resolution with a permissions error.

**Fix:**
- Confirm the ADO service connection's service principal has the **Key Vault Secrets User** role on the Key Vault (see step 4c).
- Confirm the variable group is authorised for the pipeline (Library > variable group > Pipeline permissions).
