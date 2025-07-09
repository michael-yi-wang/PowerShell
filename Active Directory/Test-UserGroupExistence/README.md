# User and Group Existence Checker

<<<<<<< HEAD
This PowerShell script checks if users and groups from a CSV file exist in both on-premises Active Directory and Azure AD (Entra ID).

## Features

- Reads user and group objects from a CSV file
- Checks existence in on-premises Active Directory
- Checks existence in Azure AD (Entra ID)
- Provides detailed reporting and summary statistics
- Exports results to CSV format
- Progress tracking and colored output
- Error handling and validation
=======
This PowerShell script checks if users and groups from a CSV file exist in both on-premises Active Directory and Entra ID (Azure AD). The script automatically detects whether each name is a user or group and provides detailed reporting including DistinguishedName and ObjectId.

## Features

- Reads user and group names from a CSV file
- Automatically detects object type (User/Group) in both environments
- Checks existence in on-premises Active Directory
- Checks existence in Entra ID (Azure AD)
- Provides detailed reporting with DistinguishedName and ObjectId
- Exports comprehensive results to CSV format
- Progress tracking and colored output
- Comprehensive error handling and validation
- Summary statistics and missing object reports
>>>>>>> michael/script/check_user_group_existence

## Prerequisites

### Required Modules
- **Active Directory PowerShell module** (part of RSAT tools)
<<<<<<< HEAD
- **Azure AD PowerShell module** (for Azure AD checks)

### Permissions
- **On-premises AD**: Read permissions to query users and groups
- **Azure AD**: Global Reader or User Administrator role (minimum)
=======
- **Azure AD PowerShell module** (for Entra ID checks)

### Permissions
- **On-premises AD**: Read permissions to query users and groups
- **Entra ID**: Global Reader or User Administrator role (minimum)
>>>>>>> michael/script/check_user_group_existence

### Installation

1. **Install RSAT tools** (for Active Directory module):
   ```powershell
   # On Windows 10/11
   Get-WindowsCapability -Online | Where-Object Name -like "Rsat.ActiveDirectory*" | Add-WindowsCapability -Online
   ```

2. **Install Azure AD PowerShell module**:
   ```powershell
   Install-Module -Name AzureAD -Force -AllowClobber
   ```

## CSV File Format

<<<<<<< HEAD
The script expects a CSV file with the following columns:

| Column | Description | Required | Default |
|--------|-------------|----------|---------|
| Name | User or group name to check | Yes | - |
| ObjectType | Type of object (User/Group) | Yes | "ObjectType" |
| Description | Optional description | No | - |

### Sample CSV Content
```csv
Name,ObjectType,Description
john.doe,User,Test user account
jane.smith,User,Another test user
IT_Support,Group,IT Support team
Sales_Team,Group,Sales department group
```

=======
The script expects a CSV file with a simple structure containing user and group names:

| Column | Description | Required | Default |
|--------|-------------|----------|---------|
| Name | User or group name to check | Yes | "Name" |

### Sample CSV Content
```csv
Name
john.doe
jane.smith
IT_Support
Sales_Team
```

**Note**: The script automatically detects whether each name is a user or group in both environments.

>>>>>>> michael/script/check_user_group_existence
## Usage

### Basic Usage
```powershell
<<<<<<< HEAD
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\users_groups.csv"
```

### With Azure AD Connection
```powershell
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\users_groups.csv" -ConnectToAzureAD
```

### Custom Column Names
```powershell
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\users_groups.csv" -ObjectTypeColumn "Type" -NameColumn "DisplayName"
=======
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\names.csv"
```

### With Entra ID Connection
```powershell
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\names.csv" -ConnectToAzureAD
```

### Custom Column Name
```powershell
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\names.csv" -NameColumn "DisplayName"
>>>>>>> michael/script/check_user_group_existence
```

### Custom Output Path
```powershell
<<<<<<< HEAD
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\users_groups.csv" -OutputPath "C:\reports\existence_report.csv"
=======
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\names.csv" -OutputPath "C:\reports\existence_report.csv"
>>>>>>> michael/script/check_user_group_existence
```

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
<<<<<<< HEAD
| CsvPath | String | Yes | - | Path to the CSV file |
| ObjectTypeColumn | String | No | "ObjectType" | Column name for object type |
| NameColumn | String | No | "Name" | Column name for object names |
| OutputPath | String | No | "UserGroupExistenceReport.csv" | Output CSV file path |
| ConnectToAzureAD | Switch | No | False | Connect to Azure AD if not connected |
=======
| CsvPath | String | Yes | - | Path to the CSV file containing user and group names |
| NameColumn | String | No | "Name" | Column name containing user/group names |
| OutputPath | String | No | "UserGroupExistenceReport.csv" | Output CSV file path |
| ConnectToAzureAD | Switch | No | False | Connect to Entra ID if not already connected |
>>>>>>> michael/script/check_user_group_existence

## Output

### Console Output
The script provides:
<<<<<<< HEAD
- Progress tracking
- Summary statistics
- List of objects not found
- Colored output for better readability

### CSV Report
The output CSV contains:
- Object name and type
- Existence status in on-premises AD
- Existence status in Azure AD
- Detailed status messages
- Timestamp of check

### Sample Output CSV
```csv
Name,ObjectType,OnPremExists,AzureExists,OnPremDetails,AzureDetails,Timestamp
john.doe,User,True,True,User found in on-premises AD,User found in Azure AD,2024-01-15T10:30:00
jane.smith,User,False,True,User not found in on-premises AD,User found in Azure AD,2024-01-15T10:30:01
IT_Support,Group,True,False,Group found in on-premises AD,Group not found in Azure AD,2024-01-15T10:30:02
=======
- Progress tracking with percentage completion
- Summary statistics for both environments
- List of objects not found in either environment
- Colored output for better readability
- Detailed error messages

### CSV Report
The output CSV contains comprehensive information:

| Column | Description |
|--------|-------------|
| Name | Object name from CSV |
| OnPremExists | Boolean indicating if found in on-premises AD |
| EntraExists | Boolean indicating if found in Entra ID |
| OnPremObjectType | Object type detected in on-premises AD (User/Group) |
| EntraObjectType | Object type detected in Entra ID (User/Group) |
| OnPremDistinguishedName | DistinguishedName from on-premises AD |
| EntraObjectId | ObjectId from Entra ID |
| OnPremDetails | Detailed status message for on-premises AD |
| EntraDetails | Detailed status message for Entra ID |
| Timestamp | When the check was performed |

### Sample Output CSV
```csv
Name,OnPremExists,EntraExists,OnPremObjectType,EntraObjectType,OnPremDistinguishedName,EntraObjectId,OnPremDetails,EntraDetails,Timestamp
john.doe,True,True,User,User,"CN=john.doe,OU=Users,DC=contoso,DC=com","12345678-1234-1234-1234-123456789012","User found in on-premises AD","User found in Entra ID","2024-01-15T10:30:00"
jane.smith,False,True,,User,,"87654321-4321-4321-4321-210987654321","Not found in on-premises AD","User found in Entra ID","2024-01-15T10:30:01"
IT_Support,True,False,Group,,"CN=IT_Support,OU=Groups,DC=contoso,DC=com",,"Group found in on-premises AD","Not found in Entra ID","2024-01-15T10:30:02"
>>>>>>> michael/script/check_user_group_existence
```

## Error Handling

The script includes comprehensive error handling:
<<<<<<< HEAD
- CSV file validation
- Module availability checks
- Connection status verification
- Individual object check failures
- Detailed error messages
=======
- CSV file validation and existence checks
- Module availability verification
- Connection status verification for both environments
- Individual object check failures with detailed error messages
- Graceful handling of connection failures
>>>>>>> michael/script/check_user_group_existence

## Troubleshooting

### Common Issues

1. **"Active Directory PowerShell module is not installed"**
   - Install RSAT tools for your Windows version
   - Ensure you're running on a domain-joined machine

<<<<<<< HEAD
2. **"Failed to connect to Azure AD"**
   - Verify you have appropriate Azure AD permissions
   - Check your internet connection
   - Ensure MFA is configured if required
=======
2. **"Failed to connect to Entra ID"**
   - Verify you have appropriate Entra ID permissions
   - Check your internet connection
   - Ensure MFA is configured if required
   - Use the `-ConnectToAzureAD` parameter to establish connection
>>>>>>> michael/script/check_user_group_existence

3. **"Column not found in CSV file"**
   - Verify the CSV file format matches the expected structure
   - Check column names for typos
<<<<<<< HEAD
   - Use custom column parameters if needed
=======
   - Use the `-NameColumn` parameter to specify custom column name
>>>>>>> michael/script/check_user_group_existence

4. **"User/Group not found"**
   - Verify the object names in the CSV are correct
   - Check if objects exist in the expected locations
   - Ensure you have appropriate permissions to query the objects

### Debug Mode
Run the script with verbose output:
```powershell
.\Test-UserGroupExistence.ps1 -CsvPath "path\to\file.csv" -Verbose
```

## Examples

### Example 1: Basic Check
```powershell
# Check users and groups from a CSV file
.\Test-UserGroupExistence.ps1 -CsvPath "C:\Users\Admin\Desktop\my_objects.csv"
```

<<<<<<< HEAD
### Example 2: With Azure AD Connection
```powershell
# Connect to Azure AD and perform full check
=======
### Example 2: With Entra ID Connection
```powershell
# Connect to Entra ID and perform full check
>>>>>>> michael/script/check_user_group_existence
.\Test-UserGroupExistence.ps1 -CsvPath "C:\Users\Admin\Desktop\my_objects.csv" -ConnectToAzureAD
```

### Example 3: Custom Configuration
```powershell
<<<<<<< HEAD
# Use custom column names and output path
.\Test-UserGroupExistence.ps1 -CsvPath "C:\Users\Admin\Desktop\my_objects.csv" `
    -ObjectTypeColumn "Type" `
=======
# Use custom column name and output path
.\Test-UserGroupExistence.ps1 -CsvPath "C:\Users\Admin\Desktop\my_objects.csv" `
>>>>>>> michael/script/check_user_group_existence
    -NameColumn "DisplayName" `
    -OutputPath "C:\Reports\existence_check_$(Get-Date -Format 'yyyyMMdd').csv"
```

## Security Considerations

- Store CSV files in secure locations
- Use appropriate permissions for the script execution
- Consider using service accounts for automated runs
- Review output files before sharing
- Ensure compliance with your organization's security policies
<<<<<<< HEAD

## Version History

- **v1.0**: Initial release with basic functionality
  - CSV file reading and validation
  - On-premises AD and Azure AD checks
  - Detailed reporting and export functionality 
=======
- Be aware that the script queries both on-premises AD and Entra ID

## Version History

- **v2.0**: Enhanced functionality
  - Automatic object type detection (User/Group)
  - Comprehensive output with DistinguishedName and ObjectId
  - Improved error handling and progress tracking
  - Enhanced summary statistics
  - Better Entra ID search capabilities (ObjectId, UserPrincipalName, DisplayName)
  - Colored console output for better readability

- **v1.0**: Initial release with basic functionality
  - CSV file reading and validation
  - On-premises AD and Entra ID checks
  - Basic reporting and export functionality 
>>>>>>> michael/script/check_user_group_existence
