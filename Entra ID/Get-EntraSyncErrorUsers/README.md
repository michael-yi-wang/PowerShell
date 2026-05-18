# Get-EntraSyncErrorUsers

Queries Microsoft Graph to collect all **Entra Connect (Azure AD Connect) synchronization errors** across users, groups, and organizational contacts, exports the results as a dated CSV, and uploads the file to a SharePoint Online document library.

Designed to run daily via **Windows Task Scheduler** (certificate-based, non-interactive) or manually in a PowerShell console (interactive login).

---

## Features

- Retrieves sync errors from all object types: **Users**, **Groups**, **Organizational Contacts**
- Categorizes every error into one of seven groups, matching the **Microsoft Entra Connect Health** portal:

| Report Category | Raw Graph Categories |
|---|---|
| **Duplicate Attribute** | `PropertyConflict`, `AttributeValueMustBeUnique`, `MatchedWithSoftmatch`, `GeneratedUpnConflict` |
| **Data Mismatch** | `InvalidSoftMatch`, `InvalidHardMatch`, `ObjectTypeMismatch`, `DomainMismatch` |
| **Data Validation Failure** | `DataValidationFailed`, `DataValidationFailure`, `DomainNotVerified`, `ExchangeObjectConflict`, `ExternalGovObjectDataValidationFailure` |
| **Large Attribute** | `LargeObject`, `ExceededAllowedLength` |
| **Federated Domain Change** | `FederatedDomainChange`, `FederatedDomainChangeError`, `InvalidFederatedUser` |
| **Existing Admin Role Conflict** | `AdminRoleConflict`, `ExistingAdminRole` |
| **Other** | All remaining categories |

- Exports a detailed CSV with one row per error (objects with multiple errors produce multiple rows)
- Creates year/month folder hierarchy in SharePoint automatically
- Writes CSV to `reports\` and log to `logs\` subdirectory under the output path
- Supports both interactive and certificate-based (app-only) authentication

---

## Prerequisites

### PowerShell Modules

```powershell
Install-Module Microsoft.Graph.Users                        -Scope CurrentUser
Install-Module Microsoft.Graph.Groups                       -Scope CurrentUser
Install-Module Microsoft.Graph.Identity.DirectoryManagement -Scope CurrentUser
Install-Module PnP.PowerShell                               -Scope CurrentUser
```

### App Registration (required for Task Scheduler / non-interactive runs)

1. Go to **Entra ID → App registrations → New registration**
2. Name: e.g. `EntraSyncErrorReport`
3. Under **API permissions → Add a permission → Microsoft Graph → Application permissions**, add:
   - `User.Read.All`
   - `Group.Read.All`
   - `OrgContact.Read.All`
4. Under **API permissions → Add a permission → SharePoint → Application permissions**, add:
   - `Sites.Selected`
5. Grant **admin consent** for both sets of permissions
6. Under **Certificates & secrets → Certificates**, upload a certificate (`.cer` file).  
   Install the matching private key (`.pfx`) in the certificate store on the machine running the script:
   - For Task Scheduler running as `SYSTEM`: `Local Machine\My`
   - For a named service account: `Current User\My`
7. Record the **Application (client) ID** and the certificate **thumbprint**

> **Note:** Microsoft Graph `Sites.Selected` and SharePoint `Sites.Selected` are **separate permissions** with different token audiences. Only the **SharePoint API** `Sites.Selected` is required for this script. Do not confuse them.

### SharePoint Permissions (site-level grant)

After adding the SharePoint `Sites.Selected` API permission, grant the app access to the specific site using PnP PowerShell (run as a SharePoint Admin):

```powershell
Connect-PnPOnline -Url "https://contoso.sharepoint.com/sites/IT" -Interactive

Grant-PnPAzureADAppSitePermission `
    -AppId      "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
    -DisplayName "EntraSyncErrorReport" `
    -Site       "https://contoso.sharepoint.com/sites/IT" `
    -Permissions Manage
```

### Certificate Private Key Access (for Task Scheduler)

When running as `SYSTEM` the private key must be accessible. To verify and fix:

1. Open **MMC** as Administrator → Add **Certificates (Local Computer)** snap-in
2. Navigate to **Personal → Certificates** → find the certificate
3. Right-click → **All Tasks → Manage Private Keys**
4. Confirm **SYSTEM** has **Full Control** (it does by default for LocalMachine\My certs)

---

## Parameters

| Parameter | Required | Default | Description |
|---|---|---|---|
| `-TenantId` | Yes | — | Entra ID tenant GUID |
| `-ClientId` | No* | — | App Registration client ID |
| `-CertificateThumbprint` | No* | — | Certificate thumbprint for non-interactive auth |
| `-SharePointSiteUrl` | No** | — | Full SharePoint site URL |
| `-SharePointDocumentLibrary` | No | `Documents` | Document library URL name (not display name) |
| `-SharePointBaseFolderPath` | No | `Entra Sync Errors` | Base folder inside the library. Supports multi-level paths e.g. `Reports/Entra Sync Errors` |
| `-OutputPath` | No | Script directory | Base directory for output. CSVs go to `{OutputPath}\reports\`, logs to `{OutputPath}\logs\` |
| `-SkipSharePointUpload` | No | — | Skip SharePoint upload; generate local files only |

\* Both `-ClientId` and `-CertificateThumbprint` must be provided together to enable non-interactive auth.  
\*\* Required unless `-SkipSharePointUpload` is specified.

---

## Usage

### Manual Run (Interactive Login)

```powershell
.\Get-EntraSyncErrorUsers.ps1 `
    -TenantId            "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -SharePointSiteUrl   "https://contoso.sharepoint.com/sites/IT" `
    -SharePointDocumentLibrary "Documents"
```

### Non-Interactive Run (Task Scheduler / Certificate Auth)

```powershell
.\Get-EntraSyncErrorUsers.ps1 `
    -TenantId              "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -ClientId              "yyyyyyyy-yyyy-yyyy-yyyy-yyyyyyyyyyyy" `
    -CertificateThumbprint "ABCDEF1234567890ABCDEF1234567890ABCDEF12" `
    -SharePointSiteUrl     "https://contoso.sharepoint.com/sites/IT" `
    -SharePointDocumentLibrary  "Documents" `
    -SharePointBaseFolderPath   "Reports/Entra Sync Errors"
```

### Local Report Only (No SharePoint Upload)

```powershell
.\Get-EntraSyncErrorUsers.ps1 `
    -TenantId           "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -SkipSharePointUpload `
    -OutputPath         "C:\Reports"
```

---

## Task Scheduler Setup

1. Open **Task Scheduler** → **Create Task**

2. **General** tab:
   - Name: `Entra Sync Error Report`
   - Run as: `SYSTEM` (has built-in access to LocalMachine\My certificates)
   - Check **Run whether user is logged on or not**
   - Check **Run with highest privileges**

3. **Triggers** tab → **New**:
   - Daily, at your preferred time (e.g. 06:00 AM)

4. **Actions** tab → **New**:
   - Program: `C:\Program Files\PowerShell\7\pwsh.exe`
   - Arguments:
     ```
     -NonInteractive -ExecutionPolicy Bypass -File "C:\Scripts\Get-EntraSyncErrorUsers\Get-EntraSyncErrorUsers.ps1" -TenantId "..." -ClientId "..." -CertificateThumbprint "..." -SharePointSiteUrl "https://contoso.sharepoint.com/sites/IT" -SharePointDocumentLibrary "Documents" -SharePointBaseFolderPath "Reports/Entra Sync Errors"
     ```

5. **Settings** tab:
   - **If the task is already running**: Do not start a new instance

---

## Output

### Directory Structure

```
<OutputPath>\
├── reports\
│   └── EntraSyncErrors_YYYYMMDD.csv
└── logs\
    └── Get-EntraSyncErrorUsers_YYYYMMDD_HHmmss.log
```

Both subdirectories are created automatically on first run.

### SharePoint Path

Files are uploaded under:
```
{Library}/{BaseFolderPath}/{YYYY}/{MMM}/EntraSyncErrors_YYYYMMDD.csv
```

Example:
```
Documents/Reports/Entra Sync Errors/2026/May/EntraSyncErrors_20260515.csv
```

### CSV Columns

| Column | Description |
|---|---|
| `ObjectType` | `User`, `Group`, or `Contact` |
| `ObjectId` | Entra ID object GUID |
| `DisplayName` | Object display name |
| `UserPrincipalName` | UPN (users only) |
| `Mail` | Primary email address |
| `OnPremisesDistinguishedName` | AD distinguished name |
| `ErrorCategory` | One of: `Duplicate Attribute`, `Data Mismatch`, `Data Validation Failure`, `Large Attribute`, `Federated Domain Change`, `Existing Admin Role Conflict`, `Other` |
| `RawErrorCategory` | Raw category value returned by Graph API |
| `OccurredDateTime` | When the error was first detected (UTC) |
| `PropertyCausingError` | The attribute name that caused the error |
| `ConflictingValue` | The conflicting attribute value |
| `AccountEnabled` | Account enabled status (users only) |
| `Department` | Department (users only) |
| `JobTitle` | Job title (users only) |
| `OnPremisesImmutableId` | Immutable ID / Source Anchor (users only) |

### Log File

**Filename:** `Get-EntraSyncErrorUsers_YYYYMMDD_HHmmss.log`  
**Location:** `<OutputPath>\logs\`

Each line is prefixed with a timestamp and level (`Info`, `Warning`, `Error`). The log includes a summary at the end showing error counts by category and object type.

---

## Troubleshooting

| Symptom | Likely Cause | Fix |
|---|---|---|
| `Insufficient privileges` on Graph query | Missing API permissions or admin consent | Re-check app permissions and grant consent |
| `AADSTS700027` certificate error | Wrong thumbprint or cert not in store | Verify thumbprint; ensure `.pfx` is installed in the correct store |
| `Keyset does not exist` | Certificate private key not accessible to the running account | Open MMC → Certificates (Local Computer) → Personal → right-click cert → **All Tasks → Manage Private Keys** → grant Read to the service account or SYSTEM |
| `Unauthorized` (401) on SharePoint | Missing **SharePoint API** `Sites.Selected` permission | Add `SharePoint → Application → Sites.Selected` in the app registration (not Microsoft Graph) and grant admin consent |
| `Access denied` on SharePoint upload | Site-level permission not granted | Run `Grant-PnPAzureADAppSitePermission` with `-Permissions Manage` for the target site |
| `File Not Found` on folder creation | Document library URL name does not match `-SharePointDocumentLibrary` | Use the URL name from the browser address bar, not the display name |
| Empty CSV every day | No sync errors exist | Expected behaviour; confirm in Entra ID portal under **Entra Connect → Sync errors** |
| `Get-MgContact` returns no results | No OrgContacts in tenant | Normal if the tenant has no synchronized mail contacts |
| `Request_UnsupportedQuery` | Older version used `onPremisesProvisioningErrors/any()` which is not an indexed Graph filter | Use the current version — it filters by `onPremisesSyncEnabled eq true` server-side |
| CSV output is zero bytes | Ran the script with no sync errors on an older version | Use the current version which writes a headers-only CSV correctly |
| "WARNING: partial data" in log | One or more Graph queries failed | Check the Warning entries above the summary in the log for the specific error |
