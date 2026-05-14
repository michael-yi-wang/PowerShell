# Teams Login Activity Report by Office Location (Get-TeamsLoginLog)

A PowerShell script that retrieves Microsoft Teams user activity for the past 30 days and filters results by office location, allowing administrators to report on Teams engagement for a specific site or office.

---

## Features

- **Office location filtering** — targets only users assigned to a specific office location in Entra ID/Azure AD.
- **30-day activity window** — downloads the full `D30` Teams user activity report via Microsoft Graph.
- **Cross-reference** — matches activity records against the filtered user list by UPN.
- **CSV export** — exports matched records to a timestamped CSV file.
- **Session logging** — colour-coded console logging (Info / Warning / Error) for clear run feedback.

---

## Prerequisites

| Requirement | Details |
|---|---|
| PowerShell | 7.x (cross-platform) |
| Module | `Microsoft.Graph` |
| Permissions | `Reports.Read.All`, `User.Read.All` |

Install the required module:

```powershell
Install-Module Microsoft.Graph -Scope CurrentUser
```

---

## Permissions

The script uses **delegated (interactive) authentication** via `Connect-MgGraph`. The signed-in account must have the following Microsoft Graph permissions consented:

| Permission | Purpose |
|---|---|
| `Reports.Read.All` | Download the Teams user activity report |
| `User.Read.All` | Query users filtered by office location |

> A **Global Reader** or **Reports Reader** role in Microsoft 365 is typically sufficient. Confirm with your tenant admin if consent is required.

---

## Usage

```powershell
# Filter by office location code; output saved to Desktop
.\Get-TeamsLoginLog.ps1 -OfficeLocation "SCO"

# Custom output path
.\Get-TeamsLoginLog.ps1 -OfficeLocation "New York" -OutputPath "C:\Reports"
```

### Parameters

| Parameter | Mandatory | Default | Description |
|---|---|---|---|
| `OfficeLocation` | Yes | — | Office location value to filter users by (e.g. `SCO`, `New York`) |
| `OutputPath` | No | Current user's Desktop | Directory where the output CSV is saved |

---

## Output

The script exports a CSV file to the specified output path (defaults to Desktop):

```
TeamsLoginLog_<OfficeLocation>_<yyyyMMdd>.csv
```

**Example:** `TeamsLoginLog_SCO_20260514.csv`

### CSV Columns

| Column | Description |
|---|---|
| `User Principal Name` | UPN of the user |
| `Last Activity Date` | Date of last recorded Teams activity |
| `Is Licensed` | Whether the user has a Teams licence |
| `Team Chat Message Count` | Number of team chat messages sent |
| `Private Chat Message Count` | Number of private chat messages sent |
| `Call Count` | Number of calls made |
| `Meeting Count` | Total meetings (organised + attended) |
| `Meetings Organized Count` | Number of meetings organised by the user |
| `Meetings Attended Count` | Number of meetings attended by the user |

> **Note:** Users with no activity in the 30-day window may not appear in the Teams activity report even if they are licensed. These users will be absent from the output.

---

## Known Limitations

| Limitation | Detail |
|---|---|
| Fixed 30-day window | The Teams activity report is fixed to `D30`; shorter date ranges are not supported by this report endpoint |
| No activity = no record | Users who have not used Teams in 30 days will not appear in the report and will be absent from the CSV |
| Office location accuracy | Filtering relies on the `officeLocation` attribute being populated and consistent in Entra ID |
| Report processing delay | Microsoft's activity reports can lag up to 48 hours behind real activity |

---

## Troubleshooting

| Symptom | Likely Cause | Resolution |
|---|---|---|
| `Insufficient privileges` | Missing consent for `Reports.Read.All` or `User.Read.All` | Ask a Global Admin to grant consent under **Entra ID → Enterprise Applications** |
| No users found | `officeLocation` attribute not set or value mismatch | Verify user attributes in Entra ID using `Get-MgUser -Filter "officeLocation eq '<value>'"` |
| Empty CSV | No users from that office location have Teams activity in the last 30 days | Confirm users are licensed and active; report may lag up to 48 hours |
| Module not found | `Microsoft.Graph` not installed | Run `Install-Module Microsoft.Graph -Scope CurrentUser` |
| Report download fails | Transient Graph API error | Re-run the script; if persistent, check Microsoft 365 service health |

---

## License

This script is provided as-is for internal administrative use. Test in a non-production environment before broad deployment.
