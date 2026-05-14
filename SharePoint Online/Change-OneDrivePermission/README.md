# Change-OneDrivePermission

Inspects and manages **Owner** and **Site Collection Admin** permissions on a OneDrive for
Business (personal) site using certificate-based app-only authentication via PnP.PowerShell.

Supports both **active** OneDrive profiles and **retained** profiles of deleted users
(shown as *Profile Missing* in the SharePoint Admin Centre). Existing site collection
admins are never removed when adding a new one.

---

## Prerequisites

| Requirement | Details |
|---|---|
| PowerShell | 7.0 or later |
| PnP.PowerShell | Latest version (see [Installation](#1-install-pnppowershell)) |
| Entra ID App Registration | Already created with a certificate credential uploaded |
| Certificate | Already issued; private key installed on the machine running the script |

---

## Setup

### 1. Install PnP.PowerShell

```powershell
Install-Module -Name PnP.PowerShell -Scope CurrentUser
```

The script will detect a missing module and remind you to install it before exiting.

---

### 2. Certificate for App-Only Authentication

The script uses a certificate (identified by its SHA1 thumbprint) to authenticate as
the app registration without a user context.

- The **public key** (`.cer`) must be uploaded to the app registration in Entra ID.
- The **private key** must be installed on the machine that runs this script.

#### Get the Thumbprint of an Existing Certificate

**Windows (PowerShell):**
```powershell
Get-ChildItem -Path Cert:\CurrentUser\My | Select-Object Subject, Thumbprint, NotAfter
```

**macOS (PowerShell):**
```powershell
security find-certificate -a -p | openssl x509 -noout -fingerprint -sha1
```

#### Create a New Self-Signed Certificate (if needed)

**Windows:**
```powershell
$cert = New-SelfSignedCertificate `
    -Subject           "CN=OneDrive-AppOnly" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy   Exportable `
    -KeySpec           Signature `
    -NotAfter          (Get-Date).AddYears(2)

$cert.Thumbprint

Export-Certificate -Cert $cert -FilePath ".\OneDrive-AppOnly.cer"
```

**macOS / Linux (openssl):**
```bash
openssl req -x509 -newkey rsa:2048 -keyout private.key -out public.cer \
    -days 730 -nodes -subj "/CN=OneDrive-AppOnly"

openssl pkcs12 -export -out OneDrive-AppOnly.pfx -inkey private.key -in public.cer
```

#### Install the Certificate

**Windows** — import into the CurrentUser personal store:
```powershell
Import-PfxCertificate -FilePath ".\OneDrive-AppOnly.pfx" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -Password (Read-Host -AsSecureString "PFX Password")
```

**macOS** — import into the login Keychain:
```bash
security import OneDrive-AppOnly.pfx -k ~/Library/Keychains/login.keychain-db
```

PnP.PowerShell resolves the thumbprint from the macOS login Keychain automatically.

#### Upload the Public Key to the App Registration

1. Open the [Azure Portal](https://portal.azure.com) → **Entra ID** → **App registrations**
2. Select your app → **Certificates & secrets** → **Certificates**
3. Click **Upload certificate** and select the `.cer` file
4. Copy the **Thumbprint** shown after upload — pass this to the script

---

## Required App Registration Permissions

### API Permission

The Entra ID app registration must have the following **Application** permission with
**admin consent** granted:

| API | Permission | Type | Purpose |
|---|---|---|---|
| SharePoint | `Sites.FullControl.All` | Application | Read and modify permissions on any OneDrive site, including retained sites of deleted users |

> **Why `Sites.FullControl.All`?**  
> Modifying ownership and site collection admin membership requires full control.
> Lower scopes such as `Sites.ReadWrite.All` do not permit permission changes.

### Directory Role

The app's **service principal** must also be assigned the **SharePoint Administrator**
directory role in Entra ID. Without it, tenant-level write operations (site unlock,
owner assignment) will fail with a Forbidden error.

To assign:
1. **Entra ID** → **Enterprise applications** → select your app
2. **Roles and administrators** → **Add assignments**
3. Search for and assign **SharePoint Administrator**

---

## Parameters

| Parameter | Parameter Set | Required | Description |
|---|---|---|---|
| `-AppId` | `Individual` | Yes | Application (Client) ID of the Entra ID app registration |
| `-Thumbprint` | `Individual` | Yes | SHA1 thumbprint of the authentication certificate |
| `-TenantId` | `Individual` | Yes | Entra ID Tenant ID (GUID) or primary domain name |
| `-ConfigFile` | `ConfigFile` | Yes | Path to a JSON file containing the three fields above |

---

## Usage

### Option A — Individual Parameters

```powershell
.\Change-OneDrivePermission.ps1 `
    -AppId      "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -Thumbprint "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" `
    -TenantId   "contoso.onmicrosoft.com"
```

### Option B — JSON Config File

```powershell
.\Change-OneDrivePermission.ps1 -ConfigFile ".\config.json"
```

**config.json format:**
```json
{
    "AppId"      : "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "Thumbprint" : "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "TenantId"   : "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

> Add `config.json` to `.gitignore` to avoid committing your App ID and Thumbprint.

---

## Interactive Menu

### Main Menu

```
+================================================+
|   Change-OneDrivePermission                    |
+================================================+

  Current Selection:
    [U] OneDrive URL  :  (not set)
    [P] User UPN      :  (not set — required to grant permissions)

  ------------------------------------------------
    [C]  Check Site Info  (Owner, Admins, Lock State, Archive Status)
    [G]  Grant Permission
    [R]  Remove Site Collection Admin
    [Q]  Quit
  ------------------------------------------------
```

| Key | Requires URL | Requires UPN | Action |
|---|---|---|---|
| `U` | — | — | Set or change the target OneDrive URL |
| `P` | — | — | Set or change the user UPN |
| `C` | Yes | No | Display site info: primary owner, all site collection admins, lock state, and archive status |
| `G` | Yes | Yes | Open the Grant Permission sub-menu |
| `R` | Yes | No | Open the Remove Site Collection Admin sub-menu |
| `Q` | — | — | Quit the script |

### Check Site Info (`C`)

Connects to the OneDrive site and the SharePoint Admin Centre and displays:

```
  +--------------------------------------------------+
  |  Site Information                                |
  +--------------------------------------------------+
  |  OneDrive : https://contoso-my.sharepoint.com/personal/john_doe_contoso_com
  |
  |  Site Status:
  |    Lock State     : Unlock
  |    Archive Status : NotArchived
  |
  |  Primary Owner:
  |    John Doe (john.doe@contoso.com)
  |
  |  Site Collection Admins:
  |    - John Doe (john.doe@contoso.com)
  |    - Admin User (admin@contoso.com)
  +--------------------------------------------------+
```

**Lock State** colour coding: `Unlock` = green, `ReadOnly` = yellow, `NoAccess` = red.  
**Archive Status** colour coding: `NotArchived` = green, `Archived`/`Reactivating` = yellow, `FullyArchived` = red.

### Grant Permission (`G`)

After pressing `G`, select the permission type:

```
+================================================+
|   Select Permission Type                       |
+================================================+

    OneDrive : https://contoso-my.sharepoint.com/personal/john_doe_contoso_com
    User     : admin@contoso.com

  ------------------------------------------------
    [1]  Owner only             (replaces current owner)
    [2]  Site Collection Admin  (added alongside existing admins)
    [3]  Both Owner and Site Collection Admin
    [B]  Back
  ------------------------------------------------
```

| Key | Permission Granted |
|---|---|
| `1` | Replaces the primary owner of the OneDrive site |
| `2` | Adds the user as a site collection admin; existing admins are kept |
| `3` | Does both: adds as site collection admin first, then sets as owner |
| `B` | Returns to the main menu without making changes |

Before any change is applied, the script displays existing admins, the pending action, and
prompts **Y/N** to confirm.

### Remove Site Collection Admin (`R`)

Lists all current site collection admins with the primary owner excluded (the primary owner
cannot be removed from this list). Select by number, comma-separated list, or `A` for all:

```
  Site Collection Admins  (primary owner excluded):

    [1]  Admin User (admin@contoso.com)
    [2]  Support Team (support@contoso.com)

    [A]  All of the above
    [B]  Back

  Enter selection (e.g. 1  or  1,3  or  A):
```

A confirmation prompt is shown before any removal is performed.

### Result Summary

After each grant or remove operation:

```
  +--------------------------------------------------+
  |  Result Summary                                  |
  +--------------------------------------------------+
  |  OneDrive : https://contoso-my.sharepoint.com/personal/john_doe_contoso_com
  |  User     : admin@contoso.com
  |
  |  Owner               : SUCCESS
  |  Site Collection Admin: SUCCESS
  +--------------------------------------------------+
```

---

## OneDrive URL Format

Only personal site collection root URLs are accepted. Sub-paths are rejected.

| Accepted | Rejected |
|---|---|
| `https://contoso-my.sharepoint.com/personal/john_doe_contoso_com` | `https://contoso.sharepoint.com/sites/finance` |
| `https://contoso-my.sharepoint.com/personal/jane_smith_contoso_com` | `https://contoso-my.sharepoint.com/personal/john/Documents` |

To find the URL of a OneDrive site (including retained/deleted profiles):

1. Go to [SharePoint Admin Centre](https://admin.microsoft.com) → **SharePoint** → **Sites** → **Active sites**
2. Filter by **Template: Personal Site**
3. For deleted users: go to **Deleted sites** or look under **Profile Missing** sites

---

## Known Limitations

> ### ⚠ Changing Primary Owner on Profile Missing Sites
>
> For OneDrive sites of **departed users in "Profile Missing" state** (account deleted,
> site retained by a retention policy), the `Set-PnPTenantSite -Owner` API call returns
> success but **does not apply the change**. This is a SharePoint Online platform
> limitation specific to app-only authentication — it is not a permissions or script issue.
>
> The script detects this silent failure by re-querying the site after the set operation
> and will report **FAILED** with an explanatory warning if the owner did not change.
>
> **Workaround:** Change the primary owner manually in the SharePoint Admin Centre:
> > **Active sites** → select the site → **Membership** tab → **Primary admin**
>
> This works because the Admin Centre uses delegated authentication (your signed-in admin
> session), which does not have the same restriction.
>
> **What the script CAN do for Profile Missing sites:**
> - ✅ Inspect site info (owner, admins, lock state, archive status)
> - ✅ Grant Site Collection Admin access
> - ✅ Remove Site Collection Admin access
> - ✅ Unlock the site if locked
> - ❌ Change primary owner (use Admin Centre instead)

---

## Log Files

Logs are written to a `logs/` subfolder in the same directory as the script:

```
Change-OneDrivePermission/
├── Change-OneDrivePermission.ps1
├── config.json            (optional, not committed)
└── logs/
    ├── Change-OneDrivePermission_20260504_143022.log
    └── Change-OneDrivePermission_20260505_090100.log
```

Each run creates a new timestamped log file. Entries are colour-coded in the
console (Green = Info, Yellow = Warning, Red = Error) and written as plain text.

---

## Notes

> **Owner vs Site Collection Admin**  
> A OneDrive site has exactly **one** primary owner and can have multiple site collection
> admins. Changing the owner replaces the previous owner. Adding a site collection admin
> never removes existing ones.

> **Retained (Profile Missing) OneDrive sites**  
> When a user is deleted from Entra ID but their OneDrive is held by a retention policy,
> the site still exists and is accessible via its original URL. The app-only connection
> used by this script works regardless of whether the original owner account is still
> active. See [Known Limitations](#known-limitations) for the primary owner restriction.

> **App-only context**  
> The script connects as the application, not as a named user. All changes are
> attributed to the app registration in the SharePoint audit log.

> **Certificate expiry**  
> If the script fails to authenticate, verify the certificate has not expired both
> in the local certificate store and in the Entra ID app registration.

> **macOS certificate support**  
> PnP.PowerShell resolves thumbprints from the macOS login Keychain. Ensure the
> certificate is imported there (not just as a loose file) before running the
> script on macOS.
