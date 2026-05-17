# Get-TeamsActivityLog

A PowerShell 7 script that retrieves the last Microsoft Teams Desktop and Mobile sign-in time for all active users in a Microsoft 365 tenant, grouped by Office Location.

---

## How It Works

The script connects to Microsoft Graph using **app-only (certificate-based) authentication** and:

1. Enumerates all **enabled, non-guest member accounts** from Entra ID.
2. Queries the **Entra ID sign-in audit logs** for successful Microsoft Teams authentications within the specified lookback window (default: 30 days).
3. Classifies each sign-in as **Desktop** or **Mobile** based on the device operating system:
   - **Mobile**: iOS, Android, Windows Phone
   - **Desktop**: Windows, macOS, Linux, ChromeOS, and all other non-empty OS values
4. Exports per-location CSV reports and writes a timestamped execution log.

---

## Output Structure

```
<script directory>/
├── report/
│   ├── <Office Location>/
│   │   └── YYYY-MM-DD_teams_activity.csv
│   └── Unknown_Location/          ← users with no Office Location set
│       └── YYYY-MM-DD_teams_activity.csv
└── logs/
    └── YYYY-MM-DD_HH-mm-ss_TeamsActivityLog.log
```

### CSV Columns

| Column | Description |
|---|---|
| `DisplayName` | User's display name |
| `UserPrincipalName` | User's UPN (email) |
| `OfficeLocation` | Office location from Entra ID profile |
| `Title` | Job title from Entra ID profile |
| `LastLoginDateTime_TeamsDesktop` | Latest successful Teams Desktop/Web sign-in (local time) |
| `LastLoginDateTime_TeamsMobile` | Latest successful Teams Mobile sign-in (local time) |

Empty cells mean the user had **no Teams activity** in the lookback period for that platform.

---

## Prerequisites

### 1. PowerShell Version

PowerShell **7.0 or later** is required.

```powershell
$PSVersionTable.PSVersion
```

### 2. Required Modules

Install via PowerShell Gallery:

```powershell
Install-Module -Name Microsoft.Graph -Scope CurrentUser -Repository PSGallery
```

The script specifically requires these sub-modules (all included in `Microsoft.Graph`):

| Module | Used For |
|---|---|
| `Microsoft.Graph.Authentication` | `Connect-MgGraph` / `Disconnect-MgGraph` |
| `Microsoft.Graph.Users` | `Get-MgUser` |
| `Microsoft.Graph.Identity.SignIns` | `Get-MgAuditLogSignIn` |

The script will check for these modules on startup and display instructions if any are missing.

### 3. Entra ID App Registration

The app must already be registered in your Entra ID tenant with the following configuration:

#### Application (not Delegated) permissions

| Permission | Type | Purpose |
|---|---|---|
| `User.Read.All` | Application | Read all user profiles |
| `AuditLog.Read.All` | Application | Read sign-in audit logs |

> **Important:** Both permissions require **admin consent**. Grant admin consent in  
> **Azure Portal → Entra ID → App registrations → \<your app\> → API permissions**.

#### Authentication

- Set the app to **not require a reply URL** (daemon / service principal use).
- No redirect URI is needed for app-only flows.

### 4. Certificate Setup

#### Step 1 — Create a self-signed certificate (if you don't already have one)

**Windows (PowerShell):**
```powershell
$cert = New-SelfSignedCertificate `
    -Subject      "CN=TeamsActivityLog" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy Exportable `
    -KeySpec Signature `
    -KeyLength 2048 `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(2)

# Export the public key (.cer) to upload to Entra
Export-Certificate -Cert $cert -FilePath "TeamsActivityLog.cer"

# Export the private key (.pfx) to use with -CertificatePath on macOS
$pwd = Read-Host -AsSecureString "Set PFX password"
Export-PfxCertificate -Cert $cert -FilePath "TeamsActivityLog.pfx" -Password $pwd
```

**macOS (OpenSSL):**
```bash
openssl req -x509 -newkey rsa:2048 -sha256 -days 730 -nodes \
    -keyout TeamsActivityLog.key \
    -out TeamsActivityLog.crt \
    -subj "/CN=TeamsActivityLog"

# Create .pfx for use with -CertificatePath
openssl pkcs12 -export \
    -out TeamsActivityLog.pfx \
    -inkey TeamsActivityLog.key \
    -in TeamsActivityLog.crt
```

#### Step 2 — Upload the public key to Entra ID

1. Navigate to **Azure Portal → Entra ID → App registrations → \<your app\>**
2. Go to **Certificates & secrets → Certificates**
3. Click **Upload certificate** and select your `.cer` (Windows) or `.crt` (macOS) file

---

## Usage

### Parameters

| Parameter | Required | Description |
|---|---|---|
| `-TenantId` | Yes | Your Entra ID tenant GUID |
| `-ClientId` | Yes | The app registration's Application (Client) ID |
| `-CertificateThumbprint` | One of these two | Certificate thumbprint from the local store |
| `-CertificatePath` | One of these two | Path to a `.pfx` certificate file |
| `-CertificatePassword` | When using `-CertificatePath` | SecureString password for the `.pfx` |
| `-DaysBack` | No (default: `30`) | Sign-in log lookback window (1–30 days) |

### Examples

**Windows — certificate thumbprint:**
```powershell
.\Get-TeamsActivityLog.ps1 `
    -TenantId             'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ClientId             'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -CertificateThumbprint 'ABCDEF1234567890ABCDEF1234567890ABCDEF12'
```

**macOS — certificate file:**
```powershell
$pwd = Read-Host -AsSecureString 'Certificate password'
.\Get-TeamsActivityLog.ps1 `
    -TenantId            'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ClientId            'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -CertificatePath     '/Users/admin/certs/TeamsActivityLog.pfx' `
    -CertificatePassword $pwd `
    -DaysBack            14
```

**Custom lookback window:**
```powershell
.\Get-TeamsActivityLog.ps1 `
    -TenantId             'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -ClientId             'xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx' `
    -CertificateThumbprint 'ABCDEF1234567890ABCDEF1234567890ABCDEF12' `
    -DaysBack             7
```

---

## Notes and Warnings

### Sign-in Log Retention Limit

> **Warning:** Entra ID sign-in logs are retained for **30 days** on Microsoft Entra ID Free and Microsoft 365 Apps tiers. The maximum value for `-DaysBack` is therefore **30**.
>
> For longer retention (up to 90 days or more), your tenant requires **Microsoft Entra ID P1 or P2** (included in Microsoft 365 E3/E5), or logs must be exported to **Azure Monitor / Microsoft Sentinel**.

### Shared Mailbox Exclusion

The script filters users by `accountEnabled eq true` and `userType eq 'Member'`. Most shared mailboxes are disabled in Entra ID and will be excluded automatically. However, **licensed shared mailboxes that are account-enabled may still appear** in the report. There is no reliable way to exclude them via Graph API alone without Exchange Online permissions.

### Performance on Large Tenants

The script reads all Microsoft Teams sign-in records for the tenant across the lookback window. For large tenants with tens of thousands of users, this can result in hundreds of thousands of records and may take **10–30 minutes** to complete. A progress counter is displayed during processing.

### Teams Web Client

Browser-based Teams access (teams.microsoft.com) is classified as **Desktop** because the underlying device OS (Windows, macOS) is reported — not the browser itself. This is the expected behaviour since web access from a desktop is categorised as a desktop session.

### Users with No Teams Activity

Users who did not sign into Teams at all during the lookback period will still appear in the report with **empty** `LastLoginDateTime` fields. This allows you to identify inactive users alongside active ones.

### Office Location Grouping

Office Location values are taken directly from Entra ID user profiles. Users with no Office Location set are grouped into a folder named `Unknown_Location`. Folder names are sanitised to remove characters that are invalid on Windows or macOS (`\ / : * ? " < > |`).

### Certificate Expiry

Self-signed certificates created for this app registration have a fixed validity period. Ensure you **rotate the certificate before it expires** to avoid authentication failures. Upload the new public key to the Entra app registration before removing the old one.

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| `Insufficient privileges` error | Admin consent not granted | Grant admin consent for `User.Read.All` and `AuditLog.Read.All` |
| `AADSTS700027` — certificate not trusted | Certificate not uploaded to Entra app | Upload the `.cer` / `.crt` public key to the app's **Certificates & secrets** |
| `CryptographicException` on macOS | Wrong password or corrupted `.pfx` | Re-export the `.pfx` and verify the password |
| Empty report (0 records) | No Teams sign-ins in the period | Increase `-DaysBack` or verify Teams is in use |
| Sign-in logs return 0 results | `AuditLog.Read.All` permission missing or no consent | Check API permissions in Entra and re-grant admin consent |
