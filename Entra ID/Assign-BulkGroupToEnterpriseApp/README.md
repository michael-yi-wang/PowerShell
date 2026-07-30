# Assign-BulkGroupToEnterpriseApp.ps1

## Overview
This script assigns all Azure AD groups matching a specified name pattern to an Enterprise Application (Service Principal) in Azure AD, using a selected appRole. It leverages the Microsoft Graph PowerShell module to automate bulk group-to-app role assignments.

## Prerequisites
- PowerShell 7.x or later
- Microsoft Graph PowerShell module (`Microsoft.Graph`)
- Permissions to assign app roles and read groups/applications in Azure AD

## Parameters
The application is identified either by name or by ID - the two parameters belong to separate parameter sets and cannot be combined.

- `-GroupNamePattern` (**Required**): Substring pattern to match group display names. Only letters, numbers, and underscores are allowed (no spaces).
- `-EnterpriseAppName` (**Required in the `ByName` set**): The display name of the target Enterprise Application (Service Principal). Applications whose display name starts with this value are listed for selection.
- `-EnterpriseAppId` (**Required in the `ById` set**): The application (client) ID or the Service Principal object ID of the target Enterprise Application. Always resolves to a single application.

## Choosing Between Name and ID
Entra ID permits several Enterprise Applications to share the same display name, so a name lookup is not guaranteed to be unique. When `-EnterpriseAppName` matches more than one application, the script prints a numbered table (display name, application ID, object ID, enabled state, type) and prompts for a selection; a single match is used without prompting. Use `-EnterpriseAppId` when the exact application is already known - both ID forms are unique within a tenant, so no prompt is shown.

## Usage
```powershell
# By display name - lists every matching app and prompts if there is more than one
./Assign-BulkGroupToEnterpriseApp.ps1 -GroupNamePattern "HR_" -EnterpriseAppName "My App"

# By application (client) ID or Service Principal object ID - always unique
./Assign-BulkGroupToEnterpriseApp.ps1 -GroupNamePattern "HR_" -EnterpriseAppId "11111111-2222-3333-4444-555555555555"
```

## What the Script Does
1. Connects to Microsoft Graph with the required permissions.
2. Searches for Azure AD groups whose display names match the provided pattern.
3. Locates the target Enterprise Application (Service Principal) by ID, or by display name with a selection prompt when multiple applications match.
4. Lists available appRoles for the application and prompts the user to select one.
5. Assigns each matching group to the application with the selected appRole.
6. Provides output and error handling for each assignment.

## Example Output
```
Connecting to Microsoft Graph...
Searching for groups with pattern: HR_
Found 3 group(s):
DisplayName      Id
-----------      --
HR_Admins        ...
HR_Users         ...
HR_Managers      ...
Press any key to continue...
Searching for enterprise app: My App
2 enterprise apps matched. Multiple apps can share the same display name - review the IDs before selecting.

Option DisplayName AppId ObjectId AccountEnabled Type
------ ----------- ----- -------- -------------- ----
     1 My App      ...   ...                True Application
     2 My App      ...   ...                True Application

Enter the Option number of the enterprise app to use (1-2): 1
Using app: My App (AppId: ..., ObjectId: ...)
Listing appRoles for the app...
Id                                   DisplayName   Value
--                                   -----------   -----
00000000-0000-0000-0000-000000000001 User         User
...
Enter the Id of the appRole to assign to the groups: 00000000-0000-0000-0000-000000000001
Assigning groups to the app with appRole: User (...)
Assigned group 'HR_Admins' to app with role 'User'
...
Assignment complete.
```

## Notes
- The script will prompt for user input to select the appRole, and to select the application when a name lookup returns more than one match.
- If no groups or appRoles are found, the script will exit with an error message.
- Make sure you have the necessary permissions in Azure AD to perform these operations.

## References
- [Get-MgServicePrincipal](https://learn.microsoft.com/powershell/module/microsoft.graph.applications/get-mgserviceprincipal?view=graph-powershell-1.0) - `startsWith` filtering requires `-ConsistencyLevel eventual` with `-CountVariable`.
- [List servicePrincipals](https://learn.microsoft.com/graph/api/serviceprincipal-list?view=graph-rest-1.0)
- [Advanced query capabilities on directory objects](https://learn.microsoft.com/graph/aad-advanced-queries)

## Author
Michael Wang 