# Get-LicensedUser

Lists the users assigned a selected license and shows whether each assignment is direct or inherited from a group.

## Prerequisites

- PowerShell 7+
- `Microsoft.Graph.Authentication` module
- Delegated permissions: `LicenseAssignment.Read.All`, `User.Read.All`, `Group.ReadBasic.All`
- A role that can read licenses and users, such as Global Reader or Directory Readers

## Usage

```powershell
./Get-LicensedUser.ps1 -TenantId "contoso.onmicrosoft.com"
```

The script lists the tenant's licenses by SKU part number (for example `SPE_E5`) and prompts you to pick one. Microsoft's [product names and service plan identifiers](https://learn.microsoft.com/entra/identity/users/licensing-service-plan-reference) page maps these to product names.

## Output

| Location | File |
|----------|------|
| `output/` | `LicensedUser_<SkuPartNumber>_<timestamp>.csv` |
| Script folder | `Get-LicensedUser_<timestamp>.log` |

The CSV has one row per user:

| Column | Graph property or meaning |
|--------|---------------------------|
| `FirstName` | `givenName` |
| `LastName` | `surname` |
| `DisplayName` | `displayName` |
| `Email` | `mail` (blank if the user has no mailbox) |
| `Title` | `jobTitle` |
| `OfficeLocation` | `officeLocation` |
| `AssignmentType` | `Direct`, `Group`, `Direct and Group`, or `Unknown` |
| `GroupName` | Assigning group. Several groups are separated by `; ` |

## Notes

- Users who hold the license through several routes get one row, so the row count is the number of licensed users.
- Group assignments in the `Error` state are ignored, because they did not grant the license. A user whose only assignment failed is not listed.
- If a group can't be read, `GroupName` shows its ID and a warning is logged.
