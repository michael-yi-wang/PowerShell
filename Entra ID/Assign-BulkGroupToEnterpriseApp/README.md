# Assign-BulkGroupToEnterpriseApp.ps1

## Overview
This script assigns all Azure AD groups matching a specified name pattern to an Enterprise Application (Service Principal) in Azure AD, using a selected appRole. It leverages the Microsoft Graph PowerShell module to automate bulk group-to-app role assignments.

## Prerequisites
- PowerShell 7.x or later
- Microsoft Graph PowerShell module (`Microsoft.Graph`)
- Permissions to assign app roles and read groups/applications in Azure AD

## Parameters
- `-GroupNamePattern` (**Required**): Substring pattern to match group display names. Only letters, numbers, and underscores are allowed (no spaces).
- `-EnterpriseAppName` (**Required**): The display name of the target Enterprise Application (Service Principal).

## Usage
```powershell
# Example usage:
./Assign-BulkGroupToEnterpriseApp.ps1 -GroupNamePattern "HR_" -EnterpriseAppName "My App"
```

## What the Script Does
1. Connects to Microsoft Graph with the required permissions.
2. Searches for Azure AD groups whose display names match the provided pattern.
3. Locates the specified Enterprise Application (Service Principal).
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
Found app: My App (Id: ...)
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
- The script will prompt for user input to select the appRole.
- If no groups or appRoles are found, the script will exit with an error message.
- Make sure you have the necessary permissions in Azure AD to perform these operations.

## Author
Michael Wang 