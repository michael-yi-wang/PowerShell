# Get-RecursiveGroupMember.ps1

## Overview

This PowerShell script uses Microsoft Graph PowerShell to retrieve all members of an Azure AD group, including members of any nested groups. It recursively resolves group membership and returns a complete list of all users and groups in the group hierarchy.

## Prerequisites

- Microsoft Graph PowerShell module (`Microsoft.Graph`)
- Permission to read group membership in Azure AD (`Group.Read.All` and `Directory.Read.All` scopes)
- Azure AD account with sufficient privileges

## Usage

```powershell
Connect-MgGraph -Scopes "Group.Read.All, Directory.Read.All"
./Get-RecursiveGroupMember.ps1 -GroupName "YourGroupName" [-RemoveDuplicateMembers] [-SaveLog] [-ExportToCsv] [-CsvPath <path>] [-IncludeGroupInfo]
### Parameters
- `GroupName` (string, mandatory): The display name of the Azure AD group to query.
- `RemoveDuplicateMembers` (switch, optional): If specified, removes duplicate members (users and groups) from the output.
- `SaveLog` (switch, optional): If specified, saves the log output to `.\log\[yyyy-MM-dd HH-mm-ss].log`.
- `ExportToCsv` (switch, optional): If specified, exports results to a CSV file.
- `CsvPath` (string, optional): Path to save the CSV file.
- `IncludeGroupInfo` (switch, optional): If specified, includes nested group info in the output.
## How It Works
1. Connects to Microsoft Graph if not already connected.
2. Finds the group by display name or ID.
3. Recursively retrieves all members, including those in nested groups.
4. Optionally removes duplicate members if `-RemoveDuplicateMembers` is used.
5. Optionally saves logs to a timestamped file in the `log` folder if `-SaveLog` is used.
6. Outputs the full member list and optionally exports to CSV.
## Example
```powershell
./Get-RecursiveGroupMember.ps1 -GroupName "Finance Team" -RemoveDuplicateMembers -SaveLog -ExportToCsv
## Output
- The script returns an array of member objects, including users and groups.
- If `-ExportToCsv` is used, results are saved to a CSV file.
- If `-SaveLog` is used, logs are saved to `.\log\[yyyy-MM-dd HH-mm-ss].log`.
## Notes
- If the group name is not found, the script will exit with an error.
- Nested groups are resolved recursively to ensure all members are included.
- Duplicate removal applies to both users and groups when `-RemoveDuplicateMembers` is specified.
## Author
GitHub Copilot
## License
MIT
# Get-RecursiveGroupMember

A PowerShell script that uses Microsoft Graph PowerShell to recursively retrieve all members of a group, including nested groups.

## Features

- **Recursive Group Membership**: Automatically traverses nested groups to get all members
- **Circular Reference Protection**: Prevents infinite loops when groups reference each other
- **Detailed User Information**: Retrieves comprehensive user properties including display name, email, job title, department, and office location
- **Flexible Input**: Accept group by name or Object ID
- **CSV Export**: Option to export results to CSV file
- **Comprehensive Logging**: Detailed logging with color-coded output
- **Group Hierarchy Tracking**: Shows the complete path through nested groups

## Prerequisites

1. **Microsoft Graph PowerShell Module**: Install the required module

   ```powershell
   Install-Module Microsoft.Graph -Force
   ```

2. **Appropriate Permissions**: The script requires the following Microsoft Graph permissions:
   - `Directory.Read.All`
   - `Group.Read.All`

3. **Authentication**: You must have appropriate permissions in your Microsoft 365 tenant

## Installation

1. Download the `Get-RecursiveGroupMember.ps1` script
2. Place it in your desired directory
3. Ensure you have the Microsoft Graph PowerShell module installed

## Example

### Basic Usage

Get all members of a group by name:

```powershell
.\Get-RecursiveGroupMember.ps1 -GroupName "IT Department"
```

Get all members of a group by Object ID:

```powershell
.\Get-RecursiveGroupMember.ps1 -GroupId "12345678-1234-1234-1234-123456789012"
```

### Advanced Usage

Export results to CSV with custom path:

```powershell
.\Get-RecursiveGroupMember.ps1 -GroupName "Security Groups" -ExportToCsv -CsvPath "C:\Temp\GroupMembers.csv"
```

Include nested group information in the output:

```powershell
.\Get-RecursiveGroupMember.ps1 -GroupName "Department Groups" -IncludeGroupInfo -ExportToCsv
```

## Parameters

| Parameter | Type | Required | Description |
|-----------|------|----------|-------------|
| `GroupName` | String | Yes* | Display name of the group to process |
| `GroupId` | String | Yes* | Object ID of the group to process |
| `ExportToCsv` | Switch | No | Export results to CSV file |
| `CsvPath` | String | No | Custom path for CSV export (defaults to current directory with timestamp) |
| `IncludeGroupInfo` | Switch | No | Include nested group information in output |

*Either `GroupName` or `GroupId` must be specified.

## Output

The script provides detailed information for each member:

- **MemberType**: "User" or "Group"
- **DisplayName**: User's display name
- **UserPrincipalName**: User's UPN
- **Email**: User's email address
- **JobTitle**: User's job title
- **Department**: User's department
- **OfficeLocation**: User's office location
- **MemberId**: Object ID of the member
- **DirectGroup**: The immediate group containing this member
- **ParentGroup**: The parent group hierarchy
- **GroupHierarchy**: Complete path through nested groups
- **ProcessingDate**: Timestamp when the member was processed

## Examples

### Example 1: Basic Group Member Retrieval

```powershell
.\Get-RecursiveGroupMember.ps1 -GroupName "Marketing Team"
```

Output:

```powershell
[2024-01-15 10:30:00] [Info] Starting recursive group member retrieval
[2024-01-15 10:30:00] [Success] Successfully connected to Microsoft Graph
[2024-01-15 10:30:00] [Success] Found target group: Marketing Team (ID: 12345678-1234-1234-1234-123456789012)
[2024-01-15 10:30:00] [Info] Processing group: Marketing Team (ID: 12345678-1234-1234-1234-123456789012)
[2024-01-15 10:30:00] [Info] Found 5 members in group 'Marketing Team'
[2024-01-15 10:30:00] [Info] Added user: John Doe (john.doe@company.com)
[2024-01-15 10:30:00] [Info] Added user: Jane Smith (jane.smith@company.com)
[2024-01-15 10:30:00] [Success] Processing complete. Found 5 total members.
[2024-01-15 10:30:00] [Info] Summary: 5 users, 0 groups
```

### Example 2: Export to CSV

```powershell
.\Get-RecursiveGroupMember.ps1 -GroupName "IT Department" -ExportToCsv
```

This will create a CSV file with all member information and display the results in the console.

## Error Handling

The script includes comprehensive error handling:

- **Connection Issues**: Automatically attempts to connect to Microsoft Graph
- **Group Not Found**: Clear error messages when groups cannot be located
- **Permission Errors**: Detailed error messages for permission issues
- **Circular References**: Detection and prevention of infinite loops
- **API Failures**: Graceful handling of Microsoft Graph API errors

## Troubleshooting

### Common Issues

1. **"Not connected to Microsoft Graph"**
   - Ensure you have the Microsoft Graph PowerShell module installed
   - Run `Connect-MgGraph` manually if needed

2. **"No group found with name"**
   - Verify the group name is correct
   - Check that you have permissions to view the group

3. **"Failed to get user details"**
   - This may occur for users without certain properties
   - The script will continue processing other members

4. **Permission Denied**
   - Ensure you have the required Microsoft Graph permissions
   - Contact your administrator if needed

### Debug Mode

To get more detailed output, run the script with verbose logging:

```powershell
.\Get-RecursiveGroupMember.ps1 -GroupName "Your Group" -Verbose
```

## Security Considerations

- The script requires elevated permissions to read group membership
- CSV exports may contain sensitive information
- Ensure proper access controls on exported files
- Consider data retention policies for exported information

## Contributing

This script follows PowerShell best practices and includes comprehensive error handling. When contributing:

1. Maintain the existing error handling patterns
2. Add appropriate logging for new functionality
3. Update this README for any new parameters or features
4. Test with various group structures including nested groups

## License

This script is provided as-is for educational and administrative purposes. Ensure compliance with your organization's policies when using this script.
