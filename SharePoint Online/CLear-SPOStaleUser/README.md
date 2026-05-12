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

### 2. Entra ID App Registration

The script authenticates as an app registration using a certificate (app-only, no user
context required). You need:

- An app registration in Entra ID with `Sites.FullControl.All` application permission (admin consent granted)
- A certificate with the **public key** (.cer) uploaded to the app registration
- The **private key** installed in the local certificate store on any machine running this script

See [Required Permissions](#required-permissions) for the full permission table.

---

### 3. Certificate for App-Only Authentication

#### Create a New Self-Signed Certificate

**Windows:**
```powershell
$cert = New-SelfSignedCertificate `
    -Subject           "CN=SPO-AppOnly" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -KeyExportPolicy   Exportable `
    -KeySpec           Signature `
    -KeyLength         2048 `
    -HashAlgorithm     SHA256 `
    -NotAfter          (Get-Date).AddYears(2)

# Note the thumbprint — you will need it for the config file
$cert.Thumbprint

# Export the public key to upload to the app registration
Export-Certificate -Cert $cert -FilePath ".\SPO-AppOnly.cer"
```

**macOS / Linux (using openssl):**
```bash
openssl req -x509 -newkey rsa:2048 -keyout private.key -out public.cer \
    -days 730 -nodes -subj "/CN=SPO-AppOnly"

# Combine into a PFX for import
openssl pkcs12 -export -out SPO-AppOnly.pfx -inkey private.key -in public.cer
```

#### Get the Thumbprint of an Existing Certificate

**Windows:**
```powershell
Get-ChildItem -Path Cert:\CurrentUser\My | Select-Object Subject, Thumbprint, NotAfter
```

**macOS:**
```powershell
security find-certificate -a -p | openssl x509 -noout -fingerprint -sha1
```

#### Install the Certificate

**Windows** — import the PFX into `CurrentUser\My`:
```powershell
Import-PfxCertificate -FilePath ".\SPO-AppOnly.pfx" `
    -CertStoreLocation "Cert:\CurrentUser\My" `
    -Password (Read-Host -AsSecureString "PFX Password")
```

**macOS** — import into the login Keychain:
```bash
security import SPO-AppOnly.pfx -k ~/Library/Keychains/login.keychain-db
```

#### Upload the Public Key to the App Registration

1. Open [Entra ID](https://entra.microsoft.com) → **App registrations** → select your app
2. Go to **Certificates & secrets** → **Certificates**
3. Click **Upload certificate** and select the `.cer` (public key only) file
4. Note the **Thumbprint** shown after upload — this value goes into `config.json`

---

### 4. Create the Config File

Copy the template and fill in the three values:

```powershell
Copy-Item ".\config.json.template" ".\config.json"
```

Edit `config.json`:
```json
{
    "AppId"      : "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx",
    "Thumbprint" : "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX",
    "TenantId"   : "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx"
}
```

| Field | Where to find it |
|-------|-----------------|
| `AppId` | Entra ID → App registrations → your app → **Application (client) ID** |
| `Thumbprint` | Entra ID → App registrations → your app → Certificates & secrets → Certificates |
| `TenantId` | Entra ID → Overview → **Tenant ID**, or your primary domain (e.g. `contoso.onmicrosoft.com`) |

> **Security:** `config.json` is not committed to source control. Add it to `.gitignore`
> and treat the file access (via NTFS permissions or macOS file ACLs) as you would any
> credential file. The certificate private key — the actual secret — stays protected in
> the OS certificate store and never appears in the config file.

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

### Default — Config File (no parameters needed)

Place `config.json` in the same folder as the script, then run:

```powershell
.\Clear-SPOStaleUser.ps1
```

The script reads `config.json` automatically.

---

### Specify an Alternate Config File

```powershell
.\Clear-SPOStaleUser.ps1 -ConfigFile "C:\Scripts\spo-config.json"
```

---

### Supply Credentials Directly

```powershell
.\Clear-SPOStaleUser.ps1 `
    -AppId      "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" `
    -Thumbprint "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX" `
    -TenantId   "contoso.onmicrosoft.com"
```

---

## Parameter Reference

| Parameter | Parameter Set | Required | Default | Description |
|---|---|---|---|---|
| `-ConfigFile` | `ConfigFile` | No | `config.json` next to script | Path to JSON config file |
| `-AppId` | `Individual` | Yes | — | Application (Client) ID of the Entra ID app registration |
| `-Thumbprint` | `Individual` | Yes | — | SHA1 thumbprint of the authentication certificate |
| `-TenantId` | `Individual` | Yes | — | Entra ID Tenant ID (GUID) or primary domain name |

`ConfigFile` is the default parameter set. Running the script with no arguments reads
`config.json` from the script directory. Individual parameters are mutually exclusive
with the config-file approach.

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
| `https://contoso-my.sharepoint.com/personal/j_doe_contoso_com` | |

**Check behaviour:**
- If the user **is found** on the site, their profile is displayed and you are prompted
  to confirm removal (Y/N).
- If the user **is not found**, a message is shown and the menu reappears — no action is
  taken.

---

## Log Files

Logs are written to a `logs/` subfolder in the same directory as the script:

```
CLear-SPOStaleUser/
├── Clear-SPOStaleUser.ps1
├── config.json.template
├── config.json               (created by admin; not committed to source control)
└── logs/
    ├── Clear-SPOStaleUser_20260504_143022.log
    └── Clear-SPOStaleUser_20260505_090100.log
```

Each run creates a new timestamped log file. Log entries are colour-coded in the
console (Green = Info, Yellow = Warning, Red = Error) and written in plain text to
the file.

---

## Certificate Renewal

When the certificate expires or is replaced:

1. Generate the new certificate and upload the new public key (`.cer`) to the Entra ID
   app registration. Keep the old certificate in the registration during the transition.
2. Install the new certificate's private key on all machines running this script.
3. Update `config.json` — change the `Thumbprint` value to the new certificate's thumbprint.
4. Remove the old certificate from the app registration once all machines are updated.

Only the `Thumbprint` field in `config.json` changes. `AppId` and `TenantId` are unchanged.

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
> **all** site collections in the tenant. Use a dedicated app registration for this
> script and do not reuse it for other purposes.
