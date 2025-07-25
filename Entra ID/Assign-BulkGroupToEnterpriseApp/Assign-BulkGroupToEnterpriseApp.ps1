<#
.SYNOPSIS
    Assigns all Azure AD groups matching a name pattern to an Enterprise Application with a selected appRole.

.DESCRIPTION
    This script connects to Microsoft Graph, searches for groups whose display names match a specified pattern, locates a target Enterprise Application (Service Principal), lists its appRoles, prompts the user to select an appRole, and assigns all matching groups to the application with the selected role.

.PARAMETER GroupNamePattern
    The pattern to match group display names (substring match). Only letters, numbers, and underscores are allowed (no spaces).

.PARAMETER EnterpriseAppName
    The display name of the Enterprise Application (Service Principal) to assign groups to.

.EXAMPLE
    .\Assign-BulkGroupToEnterpriseApp.ps1 -GroupNamePattern "HR_" -EnterpriseAppName "My App"

.NOTES
    Author: Michael Wang
    Requires: Microsoft.Graph PowerShell module
#>
param(
    [Parameter(Mandatory)]
    [string]$GroupNamePattern,
    [Parameter(Mandatory)]
    [string]$EnterpriseAppName
)

function PauseContinue {
    Write-Host "Press any key to continue..."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
}

# Connect to Microsoft Graph
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Cyan
Connect-MgGraph -Scopes "Application.ReadWrite.All", "Group.Read.All" -NoWelcome

# Find groups matching the pattern
Write-Host "Searching for groups with pattern: $GroupNamePattern" -ForegroundColor Cyan
$groups = Get-MgGroup -All | Where-Object { $_.DisplayName -like "*$GroupNamePattern*" }
if (-not $groups) {
    Write-Host "No groups found matching pattern: $GroupNamePattern" -ForegroundColor Red
    exit 1
}
Write-Host "Found $($groups.Count) group(s):" -ForegroundColor Green
$groups | Select-Object DisplayName, Id | Format-Table

# Pause for user review
PauseContinue

# Find the enterprise app (Service Principal)
Write-Host "Searching for enterprise app: $EnterpriseAppName" -ForegroundColor Cyan
$sp = Get-MgServicePrincipal -Filter "displayName eq '$EnterpriseAppName'"
if (-not $sp) {
    Write-Host "Enterprise app '$EnterpriseAppName' not found." -ForegroundColor Red
    exit 1
}
Write-Host "Found app: $($sp.DisplayName) (Id: $($sp.Id))" -ForegroundColor Green

# List appRoles for the app
Write-Host "Listing appRoles for the app..." -ForegroundColor Cyan
$appRoles = $sp.AppRoles
if (-not $appRoles) {
    Write-Host "No appRoles found for this app." -ForegroundColor Red
    exit 1
}
$appRoles | Select-Object Id, DisplayName, Value | Format-Table -AutoSize

# Prompt user to select an appRole
$roleSelection = $null
while (-not $roleSelection) {
    $roleIdInput = Read-Host "Enter the Id of the appRole to assign to the groups"
    $roleSelection = $appRoles | Where-Object { $_.Id -eq $roleIdInput }
    if (-not $roleSelection) {
        Write-Host "Invalid appRole Id. Please try again." -ForegroundColor Yellow
    }
}

# Assign each group to the app with the selected appRole
Write-Host "Assigning groups to the app with appRole: $($roleSelection.DisplayName) ($($roleSelection.Id))" -ForegroundColor Cyan
foreach ($group in $groups) {
    try {
        # Assign the group to the app with the selected appRole
        New-MgServicePrincipalAppRoleAssignment -ServicePrincipalId $sp.Id -PrincipalId $group.Id -ResourceId $sp.Id -AppRoleId $roleSelection.Id
        Write-Host "Assigned group '$($group.DisplayName)' to app with role '$($roleSelection.DisplayName)'" -ForegroundColor Green
    } catch {
        Write-Host "Failed to assign group '$($group.DisplayName)': $_" -ForegroundColor Red
    }
}

Write-Host "Assignment complete." -ForegroundColor Cyan 
