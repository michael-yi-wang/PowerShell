# AD Groups to Entra ID Sync Report Script

This PowerShell script generates a report comparing all on-premises Active Directory (AD) groups with their corresponding Entra ID (Azure AD) groups, based on the `objectSid` attribute. It helps identify which groups are synced and exist in Entra ID.

## Requirements

- Windows with PowerShell 5.1 or later
- Microsoft Graph PowerShell module (`Microsoft.Graph.Groups`)
- WinRM over SSL (port 5986) enabled on the target domain controller
- Domain admin credentials for the target domain controller
- Permissions to connect to Microsoft Graph with `Group.Read.All` scope

## Usage

1. Open PowerShell as an administrator.
2. Ensure you have the required modules:
   - `Install-Module Microsoft.Graph.Groups -Scope CurrentUser` (if not already installed)
3. Run the script with the required parameter:
   ```powershell
   .\Check-ADGroupExistenceInEntra.ps1 -DCHostName dc01.contoso.com
   ```
4. You will be prompted to:
   - Enter domain admin credentials for the specified domain controller
   - Sign in to Microsoft Graph
5. The script will generate `AD_Groups_Entra_Report.csv` in the current directory.

## Parameters

- **DCHostName** (Mandatory): The FQDN of the domain controller to connect to (must be accessible via WinRM over SSL/port 5986)

## How It Works

1. **Connectivity Check**: Verifies connectivity to the specified domain controller on port 5986 (WinRM over SSL)
2. **Remote Session**: Creates a PowerShell remoting session to the domain controller using SSL
3. **AD Module Import**: Imports the Active Directory module from the remote session
4. **Group Retrieval**: Gets all AD groups with their properties (objectSid, mail, GroupCategory, GroupScope, SamAccountName, Name)
5. **Graph Connection**: Connects to Microsoft Graph with Group.Read.All scope
6. **Comparison**: Compares each AD group's objectSid with Entra ID groups using the `onPremisesSecurityIdentifier` attribute
7. **Report Generation**: Exports results to CSV format

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

## Prerequisites

- WinRM over SSL must be enabled on the target domain controller
- The domain controller must be accessible on port 5986
- Domain admin credentials are required for the target domain controller
- Microsoft Graph PowerShell module will be automatically installed if missing

## Notes

- The script may take several minutes to run in large environments.
- Ensure you have the necessary permissions in both AD and Entra ID.
- The script uses PowerShell remoting over SSL for secure communication with the domain controller.
- Progress is displayed during group processing to show completion status. 