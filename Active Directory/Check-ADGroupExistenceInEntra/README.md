# AD Groups to Entra ID Sync Report Script

This PowerShell script generates a report comparing all on-premises Active Directory (AD) groups with their corresponding Entra ID (Azure AD) groups, based on the `objectSid` attribute. It helps identify which groups are synced and exist in Entra ID.

## Requirements

- Windows with RSAT (Active Directory module) installed
- Microsoft Graph PowerShell module (`Microsoft.Graph`)
- Permissions to read AD groups and connect to Microsoft Graph with `Group.Read.All` scope

## Usage

1. Open PowerShell as an administrator.
2. Ensure you have the required modules:
   - `Import-Module ActiveDirectory`
   - `Install-Module Microsoft.Graph -Scope CurrentUser` (if not already installed)
3. Run the script:
   ```powershell
   .\AD_Groups_Entra_Report.ps1
   ```
4. You will be prompted to sign in to Microsoft Graph.
5. The script will generate `AD_Groups_Entra_Report.csv` in the current directory.

## Output Columns

- **OnPremDisplayName**: Display name of the on-prem AD group
- **OnPremsAMAccountName**: sAMAccountName of the on-prem AD group
- **OnPremObjectSid**: objectSid of the on-prem AD group
- **GroupType**: Distribution Group or Security group
- **GroupEmail**: Email address of the group (if any)
- **ExistInEntra**: Yes/No if the group exists in Entra ID
- **EntraGroupDisplayName**: Display name of the Entra ID group (if exists)
- **EntraGroupId**: Object ID of the Entra ID group (if exists)

## Example

| OnPremDisplayName | OnPremsAMAccountName | OnPremObjectSid | GroupType          | GroupEmail         | ExistInEntra | EntraGroupDisplayName | EntraGroupId |
|-------------------|----------------------|-----------------|--------------------|--------------------|--------------|----------------------|--------------|
| HR Team           | HRTeam               | S-1-5-21-...    | Security group     | hr@contoso.com     | Yes          | HR Team              | 1234abcd...  |
| Marketing         | Marketing            | S-1-5-21-...    | Distribution Group | marketing@contoso.com | No           |                      |              |

## Notes

- The script may take several minutes to run in large environments.
- Ensure you have the necessary permissions in both AD and Entra ID. 