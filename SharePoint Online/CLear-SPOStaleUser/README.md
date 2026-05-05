# Clear-SPOStaleUser

Removes stale user profiles from SharePoint Online (SPO) site collections using
certificate-based app-only authentication via PnP.PowerShell.

A **stale user** is an account that persists in a site's User Information List even
though the user no longer exists or is no longer active in the organisation. This
can happen when a user is deleted or disabled in Entra ID but their account was never
cleaned up from individual SPO sites.

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

The script will prompt you to install the module if it is not found.

---

### 2. Certificate for App-Only Authentication

The script uses a certificate (identified by its SHA1 thumbprint) to authenticate as
the app registration without a user context. The app registration must already have the
certificate's **public key** (.cer) uploaded. The **private key** must be present on the
machine running this script.

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
    -Subject       "CN=SPO-AppOnly" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy Exportable `
    -KeySpec       Signature `
    -NotAfter      (Get-Date).AddYears(2)

# Note the thumbprint
$cert.Thumbprint

# Export public key to upload to the app registration
Export-Certificate -Cert $cert -FilePath ".\SPO-AppOnly.cer"
```

**macOS / Linux (using openssl):**
```bash
openssl req -x509 -newkey rsa:2048 -keyout private.key -out public.cer \
    -days 730 -nodes -subj "/CN=SPO-AppOnly"

# Combine into a PFX for import into Keychain (macOS) or cert store
openssl pkcs12 -export -out SPO-AppOnly.pfx -inkey private.key -in public.cer
```

#### Install the Certificate

**Windows** — import into the CurrentUser personal store:
```powershell
Import-PfxCertificate -FilePath ".\SPO-AppOnly.pfx" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -Password (Read-Host -AsSecureString "PFX Password")
```

**macOS** — import into the login Keychain:
```bash
security import SPO-AppOnly.pfx -k ~/Library/Keychains/login.keychain-db
```
PnP.PowerShell resolves the thumbprint from the macOS login Keychain automatically.

#### Upload the Public Key to the App Registration

1. Open the [Azure Portal](https://portal.azure.com) → **Entra ID** → **App registrations**
2. Select your app → **Certificates & secrets** → **Certificates**
3. Click **Upload certificate** and select the `.cer` (public key) file
4. Note the **Thumbprint** shown after upload — this is the value you pass to the script

---

## Required Permissions

The Entra ID app registration must have the following **Application** permission granted
and **admin consented**:

| API | Permission | Type | Purpose |
|---|---|---|---|
| SharePoint | `Sites.FullControl.All` | Application | Read and remove users from any site collection |

> **Why `Sites.FullControl.All`?**  
> Reading the User Information List and removing entries requires full control over the
> site. Lower permissions such as `Sites.ReadWrite.All` do not allow user deletion from
> the list.

---

## Usage

### Option A — Individual Parameters

```powershell
.\Clear-SPOStaleUser.ps1 `
    -AppId      "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -Thumbprint "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" `
    -TenantId   "contoso.onmicrosoft.com"
```

### Option B — JSON Config File

```powershell
.\Clear-SPOStaleUser.ps1 -ConfigFile ".\config.json"
```

**config.json format:**
```json
{
    "AppId"      : "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "Thumbprint" : "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "TenantId"   : "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

> Store `config.json` outside the repository or add it to `.gitignore` to avoid
> accidentally committing your App ID and Thumbprint.

---

## Parameter Reference

| Parameter | Parameter Set | Required | Description |
|---|---|---|---|
| `-AppId` | `Individual` | Yes | Application (Client) ID of the Entra ID app registration |
| `-Thumbprint` | `Individual` | Yes | SHA1 thumbprint of the authentication certificate |
| `-TenantId` | `Individual` | Yes | Entra ID Tenant ID (GUID) or primary domain name |
| `-ConfigFile` | `ConfigFile` | Yes | Path to a JSON file containing the three fields above |

---

## Interactive Menu

Once launched, the script presents a menu:

```
+================================================+
|   Clear-SPOStaleUser  -  SPO User Management   |
+================================================+

  Current Selection:
    [S] Site URL  :  (not set)
    [U] User UPN  :  (not set)

  ------------------------------------------------
    [C]  Check & Remove Stale User
    [Q]  Quit
  ------------------------------------------------
```

| Key | Action |
|---|---|
| `S` | Set or change the target site collection URL |
| `U` | Set or change the user UPN to search for |
| `C` | Connect to the site, check for the user, and optionally remove them |
| `Q` | Quit the script |

**Site URL rules:**  
Only site collection root URLs are accepted. Sub-site paths are rejected.

| Accepted | Rejected |
|---|---|
| `https://contoso.sharepoint.com` | `https://contoso.sharepoint.com/sites/site/subsite` |
| `https://contoso.sharepoint.com/sites/finance` | |
| `https://contoso.sharepoint.com/teams/marketing` | |

**Check behaviour:**
- If the user **is found** on the site, their profile is displayed and you are prompted
  to confirm removal.
- If the user **is not found**, a message is shown and the menu reappears — no action is
  taken.

---

## Log Files

Logs are written to a `logs/` subfolder in the same directory as the script:

```
Clear-SPOStaleUser/
├── Clear-SPOStaleUser.ps1
├── config.json            (optional, not committed)
└── logs/
    ├── Clear-SPOStaleUser_20260504_143022.log
    └── Clear-SPOStaleUser_20260505_090100.log
```

Each run creates a new timestamped log file. Log entries are colour-coded in the
console (Green = Info, Yellow = Warning, Red = Error) and written in plain text to
the file.

---

## Notes and Warnings

> **Irreversible action:** Removing a user from the User Information List cannot be
> undone from within this script. The user may need to visit the site again (which
> re-creates their profile) or be re-added manually if removed by mistake.

> **Group membership is lost:** If the stale user was a member of SharePoint groups on
> that site, removing them from the User Information List will also remove those group
> memberships. Document existing group membership before removal if needed.

> **App-only context:** The script connects as the application, not as a named user.
> All actions are attributed to the app registration in audit logs.

> **Certificate expiry:** Certificates have an expiry date. If the script fails to
> connect with an authentication error, check whether the certificate has expired in
> both the local store and the app registration in Entra ID.

> **macOS certificate support:** PnP.PowerShell resolves thumbprints from the macOS
> login Keychain. Ensure the certificate is imported there (not just as a loose file)
> before running the script on macOS.

> **Permissions scope:** `Sites.FullControl.All` grants the app full control over
> **all** site collections in the tenant. Follow the principle of least privilege —
> use a dedicated app registration for this script and do not reuse it for other
> purposes.
