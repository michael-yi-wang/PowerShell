# Get-TeamsActivityLog

A PowerShell 7 script that retrieves the last Microsoft Teams Desktop and Mobile sign-in time for all active users in a Microsoft 365 tenant, grouped by Office Location, with optional upload to SharePoint Online.

Both **interactive** (credential prompt / MFA) and **non-interactive** (saved credentials / silent token refresh) sign-ins are captured, so users who simply launch Teams without being re-prompted are correctly reflected in the report.

---

## How It Works

The script connects to Microsoft Graph (app-only or interactive) and:

1. Enumerates all **enabled, non-guest member accounts** from Entra ID.
2. Queries **both interactive and non-interactive Entra ID sign-in audit logs** for successful Microsoft Teams authentications within the specified lookback window (default: 30 days). The most recent timestamp across both sources is used per user per platform.
3. Classifies each sign-in as **Desktop** or **Mobile** based on the device operating system:
   - **Mobile**: iOS, Android, Windows Phone
   - **Desktop**: Windows, macOS, Linux, ChromeOS, and all other non-empty OS values
4. Exports per-location CSV reports and writes a timestamped execution log.
5. Optionally uploads each CSV to a SharePoint Online document library.

---

## Output Structure

```
<script directory>/
├── report/
│   ├── <OfficeLocation>/
│   │   └── YYYY/
│   │       └── MM/
│   │           └── <OfficeLocation>-TeamsActivity-YYYYMMDD.csv
│   └── Unknown_Location/          ← users with no Office Location set
│       └── YYYY/
│           └── MM/
│               └── Unknown_Location-TeamsActivity-YYYYMMDD.csv
└── logs/
    └── Get-TeamsActivityLog_YYYYMMDD_HHmmss.log
```

### CSV Columns

| Column | Description |
|---|---|
| `DisplayName` | User's display name |
| `Email` | Primary email address (falls back to UPN if no mail attribute) |
| `UserPrincipalName` | User's UPN |
| `OfficeLocation` | Office location from Entra ID profile |
| `Department` | Department from Entra ID profile |
| `Title` | Job title from Entra ID profile |
| `AccountEnabled` | Whether the account is enabled in Entra ID |
| `TeamsDesktopInteractiveLastLogin_UTC` | Latest Teams Desktop/Web **interactive** sign-in (UTC) |
| `TeamsDesktopNonInteractiveLastLogin_UTC` | Latest Teams Desktop/Web **non-interactive** sign-in (UTC) |
| `TeamsMobileInteractiveLastLogin_UTC` | Latest Teams Mobile **interactive** sign-in (UTC) |
| `TeamsMobileNonInteractiveLastLogin_UTC` | Latest Teams Mobile **non-interactive** sign-in (UTC) |

> **Timezone note:** All timestamps are in **UTC**. Browser-based (web client) sign-ins have no OS reported and are classified as Desktop.

Empty cells mean the user had **no activity** of that type on that platform in the lookback period.

---

## Prerequisites

### 1. PowerShell Version

PowerShell **7.0 or later** is required.

```powershell
$PSVersionTable.PSVersion
```

### 2. Required Modules

```powershell
# Microsoft Graph (covers all three required sub-modules)
Install-Module -Name Microsoft.Graph -Scope CurrentUser -Repository PSGallery

# PnP.PowerShell (only required when uploading to SharePoint)
Install-Module -Name PnP.PowerShell -Scope CurrentUser -Repository PSGallery
```

| Module | Used For |
|---|---|
| `Microsoft.Graph.Authentication` | `Connect-MgGraph`, `Disconnect-MgGraph`, `Invoke-MgGraphRequest` |
| `Microsoft.Graph.Users` | `Get-MgUser` |
| `PnP.PowerShell` | SharePoint Online upload (skipped with `-SkipSharePointUpload`) |

### 3. Entra ID App Registration

#### Microsoft Graph API Permissions (Application)

| Permission | Purpose |
|---|---|
| `User.Read.All` | Read all user profiles |
| `AuditLog.Read.All` | Read sign-in audit logs |

> Both permissions require **admin consent**. Grant it in:  
> **Azure Portal → Entra ID → App registrations → \<your app\> → API permissions → Grant admin consent**

#### SharePoint Permissions (only when uploading to SharePoint)

The same app registration requires site-level access granted via PnP.PowerShell:

```powershell
Connect-PnPOnline -Url "https://contoso.sharepoint.com/sites/IT" -Interactive
Grant-PnPAzureADAppSitePermission `
    -AppId      "<ClientId>" `
    -DisplayName "TeamsActivityLog" `
    -Site       "https://contoso.sharepoint.com/sites/IT" `
    -Permissions Manage
```

> This grants `Sites.Selected` style access — the app can only access the specified site.

### 4. Certificate Setup

#### Create a self-signed certificate

**Windows (PowerShell):**
```powershell
$cert = New-SelfSignedCertificate `
    -Subject           "CN=TeamsActivityLog" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy   Exportable `
    -KeySpec           Signature `
    -KeyLength         2048 `
    -HashAlgorithm     SHA256 `
    -NotAfter          (Get-Date).AddYears(2)

# Export public key (.cer) to upload to Entra ID
Export-Certificate -Cert $cert -FilePath "TeamsActivityLog.cer"

# Export private key (.pfx) for use on other machines or macOS
$pwd = Read-Host -AsSecureString "Set PFX password"
Export-PfxCertificate -Cert $cert -FilePath "TeamsActivityLog.pfx" -Password $pwd
```

**macOS (OpenSSL):**
```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 730 -nodes \
    -keyout TeamsActivityLog.key \
    -out    TeamsActivityLog.crt \
    -subj   "/CN=TeamsActivityLog"

openssl pkcs12 -export \
    -out    TeamsActivityLog.pfx \
    -inkey  TeamsActivityLog.key \
    -in     TeamsActivityLog.crt
```

#### Upload the public key to Entra ID

1. **Azure Portal → Entra ID → App registrations → \<your app\>**
2. **Certificates & secrets → Certificates → Upload certificate**
3. Select your `.cer` (Windows) or `.crt` (macOS) file

---

## Usage

### Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-TenantId` | Yes | — | Entra ID tenant GUID |
| `-ClientId` | For app-only | — | App registration client ID |
| `-CertificateThumbprint` | One of two | — | Certificate thumbprint from the local store |
| `-CertificatePath` | One of two | — | Path to a `.pfx` certificate file |
| `-CertificatePassword` | When using `-CertificatePath` | — | SecureString password for the `.pfx` |
| `-DaysBack` | No | `30` | Sign-in log lookback window (1–30 days) |
| `-SharePointSiteUrl` | Unless `-SkipSharePointUpload` | — | Full SharePoint site URL |
| `-SharePointDocumentLibrary` | No | `Documents` | Document library URL name |
| `-SharePointBaseFolderPath` | No | `Teams Activity` | Base folder within the library |
| `-SkipSharePointUpload` | No | — | Generate local CSVs only, skip SharePoint |

### Examples

**Interactive — local report only:**
```powershell
.\Get-TeamsActivityLog.ps1 `
    -TenantId         'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -SkipSharePointUpload
```

**Windows — certificate thumbprint with SharePoint upload:**
```powershell
.\Get-TeamsActivityLog.ps1 `
    -TenantId              'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ClientId              'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -CertificateThumbprint 'ABCDEF1234567890ABCDEF1234567890ABCDEF12' `
    -SharePointSiteUrl     'https://contoso.sharepoint.com/sites/IT' `
    -SharePointDocumentLibrary 'Documents' `
    -SharePointBaseFolderPath  'Teams Activity'
```

**macOS — PFX file with SharePoint upload, 14-day lookback:**
```powershell
$pwd = Read-Host -AsSecureString 'Certificate password'
.\Get-TeamsActivityLog.ps1 `
    -TenantId            'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ClientId            'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -CertificatePath     '/Users/admin/certs/TeamsActivityLog.pfx' `
    -CertificatePassword $pwd `
    -SharePointSiteUrl   'https://contoso.sharepoint.com/sites/IT' `
    -DaysBack            14
```

**Task Scheduler (unattended):**
```
pwsh.exe -NonInteractive -File "C:\Scripts\Get-TeamsActivityLog\Get-TeamsActivityLog.ps1"
    -TenantId "..." -ClientId "..." -CertificateThumbprint "..."
    -SharePointSiteUrl "https://contoso.sharepoint.com/sites/IT"
```

---

## SharePoint Folder Structure

When `-SkipSharePointUpload` is not specified, each location CSV is uploaded to:

```
{DocumentLibrary}/{BaseFolderPath}/{OfficeLocation}/YYYY/MM/{OfficeLocation}-TeamsActivity-YYYYMMDD.csv
```

**Example** (default settings, location `FSHO`, run on 2026-05-16):
```
Documents/Teams Activity/FSHO/2026/05/FSHO-TeamsActivity-20260516.csv
```

---

## Notes and Warnings

### Sign-in Log Retention Limit

> **Warning:** Entra ID sign-in logs are retained for **30 days** on Microsoft Entra ID Free and Microsoft 365 Apps tiers. The maximum value for `-DaysBack` is therefore **30**.
>
> For longer retention, your tenant requires **Microsoft Entra ID P1 or P2** (included in Microsoft 365 E3/E5), or logs must be exported to **Azure Monitor / Microsoft Sentinel**.

### Performance on Large Tenants

The script reads all Microsoft Teams sign-in records for the tenant across the lookback window. For large tenants this can result in hundreds of thousands of records and may take **10–30 minutes**. A progress counter is displayed during processing.

### Teams Web Client

Browser-based Teams access (`teams.microsoft.com`) is classified as **Desktop** because the underlying device OS (Windows, macOS) is reported — not the browser. This is expected behaviour.

### Users with No Teams Activity

Users who did not sign into Teams during the lookback period still appear in the report with empty `TeamsDesktopLastLogin` / `TeamsMobileLastLogin` fields, allowing you to identify inactive users alongside active ones.

### Office Location Grouping

Office Location values are taken directly from Entra ID user profiles. Users with no Office Location set are grouped into `Unknown_Location`. Folder names are sanitised to remove characters invalid on Windows or macOS (`\ / : * ? " < > |`).

### Certificate Expiry

Rotate your certificate before it expires. Upload the new public key to the Entra app registration **before** removing the old one to avoid authentication failures.

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| `Insufficient privileges` | Admin consent not granted | Grant admin consent for `User.Read.All` and `AuditLog.Read.All` |
| `AADSTS700027` — certificate not trusted | Certificate not uploaded to Entra app | Upload the `.cer` / `.crt` public key to **Certificates & secrets** |
| `CryptographicException` on macOS | Wrong password or corrupted `.pfx` | Re-export the `.pfx` and verify the password |
| SharePoint upload fails with 403 | App not granted site-level access | Run `Grant-PnPAzureADAppSitePermission` for this app and site |
| Empty report (0 records) | No Teams sign-ins in the period | Increase `-DaysBack` or verify Teams is actively used |
| Sign-in logs return 0 results | `AuditLog.Read.All` missing or no consent | Check API permissions and re-grant admin consent |
