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

## Usage

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
```
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
