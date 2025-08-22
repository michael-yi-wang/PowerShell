
# Get-RecursiveGroupMember.ps1

## Overview

This PowerShell script uses Microsoft Graph PowerShell to recursively retrieve all members of an Azure AD group, including nested groups. It supports duplicate removal, logging, CSV export, and detailed member information.

## Prerequisites

- Microsoft Graph PowerShell module (`Microsoft.Graph`)
- Permission to read group membership in Azure AD (`Group.Read.All` and `Directory.Read.All` scopes)
- Azure AD account with sufficient privileges

## Usage

```powershell
Connect-MgGraph -Scopes "Group.Read.All, Directory.Read.All"
./Get-RecursiveGroupMember.ps1 -GroupName "YourGroupName" [-RemoveDuplicateMembers] [-SaveLog] [-ExportToCsv] [-CsvPath <path>] [-IncludeGroupInfo]
```

### Parameters

- `GroupName` (string, mandatory): The display name of the Azure AD group to query.
- `GroupId` (string, mandatory if not using GroupName): The Object ID of the group to query.
- `RemoveDuplicateMembers` (switch, optional): Removes duplicate members (users and groups) from the output.
- `SaveLog` (switch, optional): Saves the log output to `./log/[yyyy-MM-dd HH-mm-ss].log`.
- `ExportToCsv` (switch, optional): Exports results to a CSV file.
- `CsvPath` (string, optional): Path to save the CSV file.
- `IncludeGroupInfo` (switch, optional): Includes nested group info in the output.

## Output

- Array of member objects, including users and groups.
- If `-ExportToCsv` is used, results are saved to a CSV file.
- If `-SaveLog` is used, logs are saved to `./log/[yyyy-MM-dd HH-mm-ss].log`.

## Example

```powershell
./Get-RecursiveGroupMember.ps1 -GroupName "Finance Team" -RemoveDuplicateMembers -SaveLog -ExportToCsv
```

## Notes

- If the group name is not found, the script will exit with an error.
- Nested groups are resolved recursively to ensure all members are included.
- Duplicate removal applies to both users and groups when `-RemoveDuplicateMembers` is specified.

## License

MIT
