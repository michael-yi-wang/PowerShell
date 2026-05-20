# Get-TeamsActivityLog

A PowerShell 7 script that retrieves the most recent Microsoft Teams activity date for all active users in a Microsoft 365 tenant, grouped by Office Location, with optional upload to SharePoint Online.

Data is sourced from the **Microsoft Graph Reports API** (`getTeamsUserActivityUserDetail` and `getTeamsDeviceUsageUserDetail`), which provides pre-aggregated per-user activity data without processing raw sign-in logs. This makes the script significantly faster than sign-in log approaches and supports lookback periods of up to **180 days**.

---

## How It Works

The script connects to Microsoft Graph (app-only or interactive) and:

1. Enumerates all **enabled, non-guest member accounts** from Entra ID (for display name, office location, department, etc.).
2. Calls the **Teams User Activity report** (`getTeamsUserActivityUserDetail`) to retrieve the last date each user participated in any Teams activity (chat, calls, meetings, etc.) within the selected period.
3. Calls the **Teams Device Usage report** (`getTeamsDeviceUsageUserDetail`) to retrieve boolean flags indicating which platform types (Desktop, Mobile, Web) each user used during the period.
4. Joins both reports to the user list by Entra Object ID, exports per-location CSV reports, and writes a timestamped execution log.
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
| `TeamsLastActivity_Date` | Most recent date the user had any Teams activity (`YYYY-MM-DD`), across all time — not limited to the selected period. Empty if the user has never had any Teams activity. |
| `TeamsUsedDesktop` | `True` if the user used Teams on Windows, macOS, Linux, or ChromeOS **within the selected period** |
| `TeamsUsedMobile` | `True` if the user used Teams on iOS or Android **within the selected period** |
| `TeamsUsedWeb` | `True` if the user used the Teams web client **within the selected period** |

> **Note:** `TeamsLastActivity_Date` is a **date** (not a timestamp) and reflects the user's **all-time** last activity — a user last active 6 months ago will still show that date even with `-Period D30`. The device-type columns (`TeamsUsedDesktop`, `TeamsUsedMobile`, `TeamsUsedWeb`) are scoped to the selected period and will be `False` if the user did not use that platform type within the period, even if they were active overall.

Empty `TeamsLastActivity_Date` means the user has **never had any Teams activity** (or has never been licensed for Teams).

---

## Prerequisites

### 1. PowerShell Version

PowerShell **7.0 or later** is required.

```powershell
$PSVersionTable.PSVersion
```

### 2. Required Modules

```powershell
# Microsoft Graph (covers all required sub-modules)
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
| `Reports.Read.All` | Read Microsoft 365 usage reports (Teams activity and device usage) |

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
| `-Period` | No | `D30` | Reporting period: `D7`, `D30`, `D90`, or `D180` |
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

**Windows — certificate thumbprint with SharePoint upload, 90-day period:**
```powershell
.\Get-TeamsActivityLog.ps1 `
    -TenantId              'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ClientId              'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -CertificateThumbprint 'ABCDEF1234567890ABCDEF1234567890ABCDEF12' `
    -Period                D90 `
    -SharePointSiteUrl     'https://contoso.sharepoint.com/sites/IT' `
    -SharePointDocumentLibrary 'Documents' `
    -SharePointBaseFolderPath  'Teams Activity'
```

**macOS — PFX file with SharePoint upload, 7-day period:**
```powershell
$pwd = Read-Host -AsSecureString 'Certificate password'
.\Get-TeamsActivityLog.ps1 `
    -TenantId            'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ClientId            'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -CertificatePath     '/Users/admin/certs/TeamsActivityLog.pfx' `
    -CertificatePassword $pwd `
    -Period              D7 `
    -SharePointSiteUrl   'https://contoso.sharepoint.com/sites/IT'
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

**Example** (default settings, location `FSHO`, run on 2026-05-19):
```
Documents/Teams Activity/FSHO/2026/05/FSHO-TeamsActivity-20260519.csv
```

---

## Notes

### Report Data Freshness

The Microsoft Graph Reports API aggregates data with a typical delay of **24–48 hours**. The `TeamsLastActivity_Date` column reflects the last confirmed activity date at the time the report was generated by Microsoft, not necessarily yesterday.

### Usage Report Anonymization

If your tenant has Microsoft 365 usage report anonymization enabled (**M365 Admin Center → Settings → Org Settings → Reports → Privacy**), the Reports API returns obfuscated user identifiers. The script detects this and logs a warning — in this state, activity dates cannot be joined to individual users and the `TeamsLastActivity_Date` and device columns will be empty for all users.

To resolve: disable anonymization in the M365 Admin Center, or assign the **Reports Reader** role to the service account so it can see de-anonymized data.

### What Counts as Teams Activity

`TeamsLastActivity_Date` only reflects dates when the user **actively participated** in Teams — not passive use such as opening the app or reading messages.

**Actions that count:**

| Action | Notes |
|---|---|
| Sent a channel or team message | Includes original posts and replies |
| Sent a private or group chat message | |
| Made or received a 1:1 call | |
| Attended or organised a meeting | Scheduled, ad-hoc, or recurring |
| Used audio, video, or screen share | |
| Any other interaction | Reactions, edits, and similar actions via `Has Other Action` |

**Actions that do NOT count:**

- Opening the Teams app
- Reading messages without responding
- Being present or showing as available (online status)
- Receiving calls or notifications without answering

> **Note:** This differs from the v2.x sign-in log approach, which captured every Teams authentication event — including simply launching the app. A user who opens Teams daily to read messages but never sends anything will have no `TeamsLastActivity_Date`, whereas the old script would have shown them as active. This makes the Reports API approach more accurate for identifying genuinely inactive users.

### Users with No Teams Activity

Users who had no Teams activity during the selected period still appear in the report with empty activity and device columns, making it easy to identify inactive users alongside active ones.

### Office Location Grouping

Office Location values are taken directly from Entra ID user profiles. Users with no Office Location set are grouped into `Unknown_Location`. Folder names are sanitised to remove characters invalid on Windows or macOS (`\ / : * ? " < > |`).

### Certificate Expiry

Rotate your certificate before it expires. Upload the new public key to the Entra app registration **before** removing the old one to avoid authentication failures.

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| `Insufficient privileges` | Admin consent not granted | Grant admin consent for `User.Read.All` and `Reports.Read.All` |
| `AADSTS700027` — certificate not trusted | Certificate not uploaded to Entra app | Upload the `.cer` / `.crt` public key to **Certificates & secrets** |
| `CryptographicException` on macOS | Wrong password or corrupted `.pfx` | Re-export the `.pfx` and verify the password |
| SharePoint upload fails with 403 | App not granted site-level access | Run `Grant-PnPAzureADAppSitePermission` for this app and site |
| All `TeamsLastActivity_Date` cells empty | Report anonymization enabled | Disable anonymization in M365 Admin Center or assign Reports Reader role |
| Empty report (0 records) | No active users or no Teams licences | Verify users are active members and Teams is deployed in the tenant |
| Reports API returns no data | `Reports.Read.All` missing or no consent | Check API permissions and re-grant admin consent |

---

## Version History

| Version | Date | Notes |
|---|---|---|
| 3.0.1 | 2026-05-19 | Fixed device usage flags always showing False: API returns `Yes`/`No` values, not `True`/`False` as documented. Fixed strict-mode crash on absent CSV columns (e.g. `Used Chrome OS` omitted by some tenants). Fixed column name normalisation for API double-space typo in `Used  Chrome OS`. |
| 3.0.0 | 2026-05-19 | Switched data source from Entra ID sign-in audit logs to Graph Reports API. Replaced `-DaysBack` / `-NonInteractiveDaysBack` / `-NonInteractiveParallelism` with `-Period`. Replaced `TeamsDesktopLastLogin_UTC` / `TeamsMobileLastLogin_UTC` / `TeamsLastLogin_UTC` columns with `TeamsLastActivity_Date`, `TeamsUsedDesktop`, `TeamsUsedMobile`, `TeamsUsedWeb`. Permission changed from `AuditLog.Read.All` to `Reports.Read.All`. Lookback extended to 180 days. |
| 2.9.0 | 2026-05-18 | Restored Desktop/Mobile columns alongside combined `TeamsLastLogin_UTC`. |
| 2.8.0 | 2026-05-17 | Simplified output to single `TeamsLastLogin_UTC`; reduced default parallelism. |
| 2.7.0 | 2026-05-16 | Parallel NI time-window chunks; simplified output to Desktop/Mobile only. |
