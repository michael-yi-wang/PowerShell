# Change-OneDrivePermission

Grants **Owner** and/or **Site Collection Admin** permissions on a OneDrive for
Business (personal) site using certificate-based app-only authentication via
PnP.PowerShell.

Supports both **active** OneDrive profiles and **retained** profiles of deleted users
(shown as *Profile Missing* in the SharePoint Admin Centre). Existing site collection
admins are never removed — new admins are always added alongside them.

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

The Entra ID app registration must have the following **Application** permission with
**admin consent** granted:

| API | Permission | Type | Purpose |
|---|---|---|---|
| SharePoint | `Sites.FullControl.All` | Application | Read and modify permissions on any OneDrive site, including retained sites of deleted users |

> **Why `Sites.FullControl.All`?**  
> Modifying ownership and site collection admin membership requires full control.
> Lower scopes such as `Sites.ReadWrite.All` do not permit permission changes.

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
    [P] User UPN      :  (not set)

  ------------------------------------------------
    [G]  Grant Permission
    [Q]  Quit
  ------------------------------------------------
```

| Key | Action |
|---|---|
| `U` | Set or change the target OneDrive URL |
| `P` | Set or change the user UPN to grant access to |
| `G` | Open the permission type sub-menu |
| `Q` | Quit the script |

### Permission Sub-Menu

After pressing `G`, you select what to grant:

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

### Confirmation & Result

Before any change is applied, the script:

1. Displays all **existing** site collection admins.
2. Shows a summary of the pending action.
3. Warns if the current owner will be replaced (options 1 and 3).
4. Prompts **Y/N** to confirm.

After the operation, a result summary is shown:

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

The menu reappears automatically after each operation, ready for the next input.

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
> active.

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
