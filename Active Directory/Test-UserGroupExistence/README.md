# User and Group Existence Checker

This PowerShell script checks if users and groups from a CSV file exist in both on-premises Active Directory and Azure AD (Entra ID).

## Features

- Reads user and group objects from a CSV file
- Checks existence in on-premises Active Directory
- Checks existence in Azure AD (Entra ID)
- Provides detailed reporting and summary statistics
- Exports results to CSV format
- Progress tracking and colored output
- Error handling and validation

## Prerequisites

### Required Modules
- **Active Directory PowerShell module** (part of RSAT tools)
- **Azure AD PowerShell module** (for Azure AD checks)

### Permissions
- **On-premises AD**: Read permissions to query users and groups
- **Azure AD**: Global Reader or User Administrator role (minimum)

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

## Usage

### Basic Usage
```powershell
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\users_groups.csv"
```

### With Azure AD Connection
```powershell
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\users_groups.csv" -ConnectToAzureAD
```

### Custom Column Names
```powershell
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\users_groups.csv" -ObjectTypeColumn "Type" -NameColumn "DisplayName"
```

### Custom Output Path
```powershell
.\Test-UserGroupExistence.ps1 -CsvPath "C:\path\to\users_groups.csv" -OutputPath "C:\reports\existence_report.csv"
```

## Parameters

| Parameter | Type | Required | Default | Description |
|-----------|------|----------|---------|-------------|
| CsvPath | String | Yes | - | Path to the CSV file |
| ObjectTypeColumn | String | No | "ObjectType" | Column name for object type |
| NameColumn | String | No | "Name" | Column name for object names |
| OutputPath | String | No | "UserGroupExistenceReport.csv" | Output CSV file path |
| ConnectToAzureAD | Switch | No | False | Connect to Azure AD if not connected |

## Output

### Console Output
The script provides:
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
```

## Error Handling

The script includes comprehensive error handling:
- CSV file validation
- Module availability checks
- Connection status verification
- Individual object check failures
- Detailed error messages

## Troubleshooting

### Common Issues

1. **"Active Directory PowerShell module is not installed"**
   - Install RSAT tools for your Windows version
   - Ensure you're running on a domain-joined machine

2. **"Failed to connect to Azure AD"**
   - Verify you have appropriate Azure AD permissions
   - Check your internet connection
   - Ensure MFA is configured if required

3. **"Column not found in CSV file"**
   - Verify the CSV file format matches the expected structure
   - Check column names for typos
   - Use custom column parameters if needed

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

### Example 2: With Azure AD Connection
```powershell
# Connect to Azure AD and perform full check
.\Test-UserGroupExistence.ps1 -CsvPath "C:\Users\Admin\Desktop\my_objects.csv" -ConnectToAzureAD
```

### Example 3: Custom Configuration
```powershell
# Use custom column names and output path
.\Test-UserGroupExistence.ps1 -CsvPath "C:\Users\Admin\Desktop\my_objects.csv" `
    -ObjectTypeColumn "Type" `
    -NameColumn "DisplayName" `
    -OutputPath "C:\Reports\existence_check_$(Get-Date -Format 'yyyyMMdd').csv"
```

## Security Considerations

- Store CSV files in secure locations
- Use appropriate permissions for the script execution
- Consider using service accounts for automated runs
- Review output files before sharing
- Ensure compliance with your organization's security policies

## Version History

- **v1.0**: Initial release with basic functionality
  - CSV file reading and validation
  - On-premises AD and Azure AD checks
  - Detailed reporting and export functionality 