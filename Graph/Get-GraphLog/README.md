# Microsoft 365 Audit Log Retrieval Tool (Get-GraphLog)

An interactive PowerShell tool for helpdesk agents to retrieve unified audit logs from Microsoft 365 services — Exchange Online, SharePoint, OneDrive, and Microsoft Teams — using app-only certificate authentication via Microsoft Graph.

---

## Features

- **App-only certificate authentication** — no helpdesk agent sign-in required; a single X.509 certificate is distributed to agent machines.
- **Interactive menu** — agents can run multiple searches in a single session without restarting.
- **Exchange Online** — retrieves all mailbox audit events (HardDelete, SoftDelete, Move, SendAs, etc.) for a user UPN. Distinguishes **Owner**, **Delegate**, and **Admin** logon types.
- **SharePoint** — retrieves all site activity (file access, download, upload, delete, sharing, permission changes, etc.) for a given site URL.
- **OneDrive** — retrieves drive activity by user UPN or OneDrive URL.
- **Microsoft Teams** — retrieves team/channel events (member add/remove, team creation, channel creation, etc.) by team name keyword.
- **JSON expansion** — raw `auditData` fields returned by Graph are automatically expanded into human-readable columns.
- **CSV export** — each search exports results to a timestamped CSV file in the `outputs/` subfolder.
- **Session logging** — all actions and warnings are written to a timestamped log file under the `logs/` subfolder.

---

## Prerequisites

| Requirement | Details |
|---|---|
| PowerShell | 7.x (cross-platform) |
| Module | `Microsoft.Graph.Authentication` |
| Azure AD App | App Registration with `AuditLogsQuery.Read.All` and a certificate (see setup below) |

Install the required module:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

---

## App Registration & Certificate Setup

Follow these steps once as an admin. Required role: **Application Administrator** or **Global Administrator**.

---

### Step 1 — Create the App Registration

1. Sign in to the [Microsoft Entra admin centre](https://entra.microsoft.com).
2. Go to **Identity → Applications → App registrations**.
3. Click **+ New registration**.
4. Fill in:
   - **Name**: `M365-AuditLog-Helpdesk`
   - **Supported account types**: *Accounts in this organizational directory only*
   - **Redirect URI**: leave blank
5. Click **Register**.
6. On the overview page, copy and save:
   - **Application (client) ID** → this is your `-ClientId` parameter
   - **Directory (tenant) ID** → this is your `-TenantId` parameter

---

### Step 2 — Assign API Permissions

1. In the app registration, go to **API permissions**.
2. Click **+ Add a permission → Microsoft Graph → Application permissions**.
3. Search for and select:

   | Permission | Type | Purpose |
   |---|---|---|
   | `AuditLogsQuery.Read.All` | Application | Read Microsoft Purview Unified Audit Log (required for this script) |
   | `AuditLog.Read.All` | Application | Read Azure AD sign-in and directory audit logs (optional) |

   > **Important:** `AuditLogsQuery.Read.All` and `AuditLog.Read.All` are **different permissions**. This script uses the Microsoft Purview Audit Log Search API (`/beta/security/auditLog/queries`) which specifically requires `AuditLogsQuery.Read.All`.

4. Click **Add permissions**.
5. Click **Grant admin consent for [your tenant]** and confirm.
   The status column must show a green **Granted** tick before proceeding.

---

### Step 3 — Generate a Certificate

A self-signed certificate is sufficient for internal helpdesk use. Run the commands below **once** on a trusted admin machine.

#### Option A — Windows (PowerShell)

```powershell
# Generate a self-signed certificate valid for 2 years
$Cert = New-SelfSignedCertificate `
    -Subject "CN=M365-AuditLog-Helpdesk" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy Exportable `
    -KeySpec Signature `
    -KeyLength 2048 `
    -KeyAlgorithm RSA `
    -HashAlgorithm SHA256 `
    -NotAfter (Get-Date).AddYears(2)

# Display the thumbprint — save this value
Write-Host "Thumbprint: $($Cert.Thumbprint)" -ForegroundColor Green

# Export the PUBLIC key (.cer) — this is uploaded to the app registration
Export-Certificate -Cert $Cert -FilePath "M365AuditLogHelpdesk.cer"

# Export the PRIVATE key (.pfx) — this is distributed to helpdesk agent machines
$PfxPassword = Read-Host "Enter a strong password for the .pfx file" -AsSecureString
Export-PfxCertificate -Cert $Cert -FilePath "M365AuditLogHelpdesk.pfx" -Password $PfxPassword
```

#### Option B — macOS / Linux (OpenSSL)

```bash
# Generate private key and self-signed certificate
openssl req -x509 -newkey rsa:2048 -days 730 -nodes \
  -keyout key.pem -out cert.pem \
  -subj "/CN=M365-AuditLog-Helpdesk"

# Bundle into a .pfx for distribution to agent machines (will prompt for export password)
openssl pkcs12 -export -out M365AuditLogHelpdesk.pfx -inkey key.pem -in cert.pem

# Convert .pem to .cer (DER format) for upload to app registration
openssl x509 -in cert.pem -outform DER -out M365AuditLogHelpdesk.cer
```

> **Keep `M365AuditLogHelpdesk.pfx` and `key.pem` secure.** Only distribute the `.pfx` to authorised agent machines. The `.cer` file contains only the public key and is safe to upload.

---

### Step 4 — Upload the Certificate to the App Registration

1. In the app registration, go to **Certificates & secrets**.
2. Click the **Certificates** tab.
3. Click **+ Upload certificate**.
4. Browse to and select `M365AuditLogHelpdesk.cer`.
5. Add a description (e.g. `Helpdesk Script Cert`) and click **Add**.
6. The certificate now appears in the list. Note the **Thumbprint** shown — agents will use this with `-CertificateThumbprint`.

> **Certificate expiry:** Set a calendar reminder 30 days before the certificate's expiry date. Renew by generating a new certificate, uploading the new `.cer`, distributing the new `.pfx` to agents, and removing the old certificate from the app registration.

---

### Step 5 — Distribute the Certificate to Helpdesk Agent Machines

How agents use the certificate depends on their operating system.

#### Windows — import into certificate store (recommended)

Import the `.pfx` once per machine. After import, agents use `-CertificateThumbprint` with no password prompt at runtime.

```powershell
# Run once per agent machine
$PfxPassword = Read-Host "Enter the .pfx password" -AsSecureString
Import-PfxCertificate -FilePath "M365AuditLogHelpdesk.pfx" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -Password $PfxPassword

# Confirm import and retrieve the thumbprint
Get-ChildItem Cert:\CurrentUser\My |
    Where-Object { $_.Subject -like "*M365-AuditLog*" } |
    Select-Object Subject, Thumbprint, NotAfter
```

Then run the script with:
```powershell
.\Get-GraphLog.ps1 -TenantId "..." -ClientId "..." -CertificateThumbprint "<thumbprint>"
```

#### macOS / Linux — use .pfx file directly

The `Cert:` certificate store drive is **not available on macOS or Linux**. Distribute the `.pfx` file to each agent and use `-CertificatePath` instead:

```powershell
.\Get-GraphLog.ps1 -TenantId "..." -ClientId "..." -CertificatePath "/path/to/M365AuditLogHelpdesk.pfx"
```

The script will prompt for the `.pfx` password on first run. Store the `.pfx` in a secure location on the agent's machine (e.g. `~/Keys/` with `chmod 600`).

---

## Usage

### Windows — certificate imported in local store (recommended)

```powershell
.\Get-GraphLog.ps1 `
    -TenantId "contoso.onmicrosoft.com" `
    -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -CertificateThumbprint "A1B2C3D4E5F6A1B2C3D4E5F6A1B2C3D4E5F6A1B2"
```

### macOS / Linux — load certificate from .pfx file

> The `Cert:` store drive is not available on macOS/Linux. Use `-CertificatePath` instead.

```powershell
# Will prompt for the .pfx password interactively
.\Get-GraphLog.ps1 `
    -TenantId "contoso.onmicrosoft.com" `
    -ClientId "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -CertificatePath "/path/to/M365AuditLogHelpdesk.pfx"
```

Once launched, an interactive menu is displayed. The agent selects a service, enters the target (UPN, URL, or team name), specifies the date range, and the script retrieves and exports the results.

### Parameters

| Parameter | Mandatory | Parameter Set | Description |
|---|---|---|---|
| `TenantId` | Yes | Both | Tenant ID (GUID) or domain (e.g. `contoso.onmicrosoft.com`) |
| `ClientId` | Yes | Both | Application (client) ID of the Entra ID app registration |
| `CertificateThumbprint` | Yes* | `Thumbprint` | Thumbprint of certificate in `Cert:\CurrentUser\My` |
| `CertificatePath` | Yes* | `PfxFile` | Path to a `.pfx` certificate file |
| `CertificatePassword` | No | `PfxFile` | Password for the `.pfx` file; prompted if omitted |

*Use either `CertificateThumbprint` **or** `CertificatePath` — not both.

---

## Search Options

### Exchange Online — by User UPN

Retrieves all mailbox audit events for the specified user across five record types:
`exchangeItem`, `exchangeItemGroup`, `exchangeItemAggregated`, `exchangeAdmin`, `exchangeSearch`

**Covered operations:**

| Operation | Description | Enabled by Default? |
|---|---|---|
| `HardDelete` | Message permanently deleted | Yes |
| `SoftDelete` | Message moved to Recoverable Items (Purges) | Yes |
| `MoveToDeletedItems` | Message moved to Deleted Items folder | Yes |
| `Move` | Message moved to any other folder | **No — must be enabled per mailbox** |
| `SendAs` | Email sent as another user | Yes |
| `SendOnBehalf` | Email sent on behalf of another user | Yes |
| `Create` | Item created in mailbox | Yes |
| `Update` | Item properties updated | Yes |
| `Copy` | Item copied to another folder | Yes |
| `FolderBind` | Folder opened/accessed | Yes (delegates/admins) |
| `UpdateFolderPermissions` | Folder permissions changed | Yes |
| `UpdateInboxRules` | Inbox rules added/modified/removed | Yes |
| `UpdateCalendarDelegation` | Calendar delegation changed | Yes |
| `MailItemsAccessed` | Mail items accessed (forensic) | **E5 / Purview Audit Premium only** |
| `Set-Mailbox` / admin cmdlets | Admin configuration changes | Yes (via `exchangeAdmin`) |
| `SearchQueryInitiated` | Mailbox search performed | Yes (via `exchangeSearch`) |

> **Important — `Move` operations are NOT audited by default.** To enable them per mailbox:
> ```powershell
> Set-Mailbox -Identity user@contoso.com `
>     -AuditOwner    @{Add='Move','MoveToDeletedItems'} `
>     -AuditDelegate @{Add='Move','MoveToDeletedItems'} `
>     -AuditAdmin    @{Add='Move','MoveToDeletedItems'}
> ```

> **`MailItemsAccessed`** is captured via `exchangeItemAggregated` and requires a **Microsoft 365 E5** or **Microsoft Purview Audit Premium** licence. It will return no records on E3 tenants.

The **LogonType** column indicates who accessed the mailbox:

| Value | Meaning |
|---|---|
| `Owner` | The mailbox owner accessed their own mailbox |
| `Admin` | An administrator accessed the mailbox |
| `Delegate` | Someone with delegated access (e.g. shared mailbox, full-access delegate) |

---

### SharePoint — by Site URL

Retrieves all activity on a SharePoint site across nine record types covering the full activity surface:
`sharePoint`, `sharePointFileOperation`, `sharePointListItemOperation`, `sharePointSharingOperation`,
`sharePointCommentOperation`, `sharePointListOperation`, `sharePointContentTypeOperation`,
`sharePointFieldOperation`, `sharePointSearch`

**Covered operations:**

| Category | Example Operations |
|---|---|
| File operations | `FileAccessed`, `FileDownloaded`, `FileUploaded`, `FileDeleted`, `FileRenamed`, `FileMoved`, `FileCopied`, `FileCheckedIn`, `FileCheckedOut` |
| Sharing | `SharingInvitationCreated`, `SharingSet`, `AnonymousLinkCreated`, `SharingRevoked` |
| Permissions | `PermissionLevelAdded`, `PermissionLevelRemoved`, `SitePermissionsModified` |
| Lists & items | `ListCreated`, `ListDeleted`, `ListItemCreated`, `ListItemUpdated`, `ListItemDeleted` |
| Content types | `ContentTypeAdded`, `ContentTypeModified`, `ContentTypeDeleted` |
| Fields (columns) | `ColumnCreated`, `ColumnModified`, `ColumnDeleted` |
| Comments | `CommentCreated`, `CommentDeleted` |
| Pages & search | `PageViewed`, `SearchQueryPerformed` |

Enter the site URL in the format:
`https://contoso.sharepoint.com/sites/SiteName`

---

### OneDrive — by UPN or Drive URL

Search by **user UPN** to retrieve all OneDrive activity for that user, or by **drive URL** (the personal SharePoint URL):
`https://contoso-my.sharepoint.com/personal/firstname_lastname_contoso_com`

OneDrive is covered by the `oneDrive` record type. Additionally, `sharePointFileOperation` (included in the SharePoint filter) also covers OneDrive file operations, providing overlapping coverage.

Common operations: `FileAccessed`, `FileUploaded`, `FileDownloaded`, `FileDeleted`, `FileRenamed`, `FileSyncUploadedFull`, `FileSyncDownloadedFull`, `FileMalwareDetected`

---

### Microsoft Teams — by Team Name

Performs a keyword search across Teams audit records across three record types:
`microsoftTeams`, `microsoftTeamsAdmin`, `microsoftTeamsDevice`

**Covered operations:**

| Category | Example Operations |
|---|---|
| Teams & channels | `TeamCreated`, `TeamDeleted`, `TeamUpdated`, `ChannelCreated`, `ChannelDeleted` |
| Members | `MemberAdded`, `MemberRemoved`, `MemberRoleChanged` |
| Meetings | `MeetingCreated`, `MeetingDeleted`, `MeetingParticipantDetail` |
| Apps & tabs | `AppInstalled`, `AppUninstalled`, `TabCreated`, `TabUpdated`, `TabDeleted` |
| Admin policies | `PolicyAssigned`, `TeamsTenantSettingChanged` (via `microsoftTeamsAdmin`) |
| Devices | `DeviceConfigurationChanged`, `DeviceUpdated` (via `microsoftTeamsDevice`) |

> **Not covered — requires additional app deployment:**
> - **Teams Shifts** activities → record type `microsoftTeamsShifts` (requires Shifts app)
> - **Teams Approvals** activities → record type `teamsEasyApprovalsAuditRecord` (requires Approvals app)
>
> Uncomment the relevant lines in `$TeamsRecordTypes` in the script if your organisation uses these apps.

> **Note:** Team name search uses keyword matching and may return records from similarly named teams. Review the `TeamName` column to confirm relevance.

---

## Output Files

Each search produces output files in two subfolders next to the script:

| File | Location | Description |
|---|---|---|
| `<platform>_<id>_<yyyyMMddHHmmss>.csv` | `outputs/` | Audit records in CSV format |
| `GraphLog_<yyyyMMddHHmmss>.log` | `logs/` | Full session log (all searches in a session share one log) |

**CSV filename examples by service:**

| Service | Example filename |
|---|---|
| Exchange Online | `exchange_user@contoso.com_20260505161700.csv` |
| SharePoint | `sharepoint_Marketing_20260505161700.csv` |
| OneDrive (by UPN) | `onedrive_user@contoso.com_20260505161700.csv` |
| OneDrive (by URL) | `onedrive_firstname_lastname_contoso_com_20260505161700.csv` |
| Teams | `teams_TeamName_20260505161700.csv` |

### CSV Columns by Service

**Exchange Online**

`DateTime`, `Service`, `RecordType`, `Operation`, `LogonType`, `UserId`, `MailboxOwnerUPN`, `ClientIP`, `ClientInfo`, `ExternalAccess`, `FolderPath`, `ItemSubject`, `AffectedItemsCount`, `AffectedItemsSubjects`, `AffectedItemsFolders`, `ResultStatus`, `ObjectId`

**SharePoint**

`DateTime`, `Service`, `RecordType`, `Operation`, `UserId`, `SiteUrl`, `WebUrl`, `ItemType`, `FileName`, `FilePath`, `EventSource`, `UserAgent`, `ClientIP`, `ObjectId`

**OneDrive**

`DateTime`, `Service`, `RecordType`, `Operation`, `UserId`, `SiteUrl`, `FileName`, `FilePath`, `FileSizeBytes`, `UserAgent`, `ClientIP`, `ObjectId`

**Microsoft Teams**

`DateTime`, `Service`, `RecordType`, `Operation`, `UserId`, `TeamName`, `ChannelName`, `CommunicationType`, `Members`, `TabName`, `ClientIP`, `ObjectId`

---

## Known Limitations

| Limitation | Detail |
|---|---|
| Audit log retention | 90 days (standard licence) or 1 year (E5 / Microsoft Purview Audit Premium) |
| API endpoint | Uses the `/beta` endpoint — Microsoft may change behaviour without notice |
| Query processing time | Server-side queries can take up to 10 minutes; the script polls every 10 seconds |
| Pagination | Results are capped at 1,000 records per page; the script fetches all pages automatically and warns when multiple pages are present |
| Teams search accuracy | Keyword search may return partial matches; filter results by the `TeamName` column |
| SharePoint fallback | If `objectIdFilters` returns no results, the script retries automatically using `keywordFilter` against the site URL |
| Rate limits | Microsoft Graph imposes service-side throttling; large date ranges may be throttled — narrow the range if queries consistently fail |

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| `AADSTS700027` or certificate error | Certificate thumbprint wrong or cert not imported | Re-import `.pfx` and verify thumbprint with `Get-ChildItem Cert:\CurrentUser\My` |
| `AADSTS70011` invalid scope | Wrong ClientId or permission not granted | Verify app registration and admin consent |
| `Insufficient privileges` | Admin consent not granted | Re-grant consent under **API permissions** in the app registration |
| Query returns 0 results | Wrong UPN/URL, no activity in range, or audit not enabled | Verify mailbox/site auditing is enabled in the compliance centre |
| Query times out | Very large date range or high activity volume | Narrow date range to 7–14 days |
| `AuditData` fields are empty | Activity type does not populate those fields | Normal — not all operations populate every field |
| Module not found | `Microsoft.Graph` not installed | Run `Install-Module Microsoft.Graph -Scope CurrentUser` |

### Enable Mailbox Auditing (Exchange)

If Exchange returns no results, verify auditing is enabled:

```powershell
# Connect to Exchange Online PowerShell first
Get-Mailbox -Identity user@contoso.com | Select-Object AuditEnabled, AuditOwner, AuditDelegate, AuditAdmin
```

To enable:

```powershell
Set-Mailbox -Identity user@contoso.com -AuditEnabled $true
```

### Verify Unified Audit Log is Enabled (Tenant-wide)

In the [Microsoft Purview compliance portal](https://compliance.microsoft.com):
Go to **Audit → Start recording user and admin activity** (if the banner appears).

---

## Security Notes

- The `.pfx` file contains the private key — treat it as a secret. Distribute only to authorised agent machines via a secure channel.
- The `.cer` file contains only the public key and can be shared freely for upload purposes.
- Set a calendar reminder 30 days before the certificate's `NotAfter` date to renew it before expiry.
- The app registration should hold only the minimum required permission (`AuditLog.Read.All`).
- Consider restricting the app to specific users via an **app access policy** if your environment supports it.

---

## License

This script is provided as-is for internal helpdesk use. Test in a non-production environment before broad deployment.
