<#
.SYNOPSIS
    Assigns all Azure AD groups matching a name pattern to an Enterprise Application with a selected appRole.

.DESCRIPTION
    This script connects to Microsoft Graph, searches for groups whose display names match a specified pattern, locates a target Enterprise Application (Service Principal) by display name or by ID, lists its appRoles, prompts the user to select an appRole, and assigns all matching groups to the application with the selected role.

    When the application is located by display name, every matching Service Principal is listed so the correct one can be picked - Entra ID allows multiple Enterprise Applications to share the same display name. Locating the application by ID (application/client ID or Service Principal object ID) always resolves to a single, unambiguous application.

.PARAMETER GroupNamePattern
    The pattern to match group display names (substring match). Only letters, numbers, and underscores are allowed (no spaces).

.PARAMETER EnterpriseAppName
    The display name of the Enterprise Application (Service Principal) to assign groups to. Display names beginning with this value are returned, and the matching applications are listed for selection.

.PARAMETER EnterpriseAppId
    The ID of the Enterprise Application to assign groups to. Accepts either the application (client) ID or the Service Principal object ID. This always identifies exactly one application.

.EXAMPLE
    .\Assign-BulkGroupToEnterpriseApp.ps1 -GroupNamePattern "HR_" -EnterpriseAppName "My App"

    Searches for Enterprise Applications named "My App" and prompts for a selection when more than one is found.

.EXAMPLE
    .\Assign-BulkGroupToEnterpriseApp.ps1 -GroupNamePattern "HR_" -EnterpriseAppId "11111111-2222-3333-4444-555555555555"

    Targets a single Enterprise Application by its application (client) ID or Service Principal object ID.

.NOTES
    Author: Michael Wang
    Requires: Microsoft.Graph PowerShell module
#>
[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(Mandatory)]
    [string]$GroupNamePattern,
    [Parameter(Mandatory, ParameterSetName = 'ByName')]
    [string]$EnterpriseAppName,
    [Parameter(Mandatory, ParameterSetName = 'ById')]
    [ValidatePattern('^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$')]
    [string]$EnterpriseAppId
)

function PauseContinue {
    Write-Host "Press any key to continue..."
    $null = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown');
}

function Select-ServicePrincipal {
    <#
    .SYNOPSIS
        Displays the supplied Service Principals and returns the one selected by the user.
    #>
    param(
        [Parameter(Mandatory)]
        [object[]]$ServicePrincipal
    )

    # A single match needs no prompt.
    if ($ServicePrincipal.Count -eq 1) {
        return $ServicePrincipal[0]
    }

    Write-Host "$($ServicePrincipal.Count) enterprise apps matched. Multiple apps can share the same display name - review the IDs before selecting." -ForegroundColor Yellow

    $optionNumber = 0
    $ServicePrincipal | ForEach-Object {
        [PSCustomObject]@{
            Option         = ++$optionNumber
            DisplayName    = $_.DisplayName
            AppId          = $_.AppId
            ObjectId       = $_.Id
            AccountEnabled = $_.AccountEnabled
            Type           = $_.ServicePrincipalType
        }
    } | Format-Table -AutoSize | Out-Host

    while ($true) {
        $selection = Read-Host "Enter the Option number of the enterprise app to use (1-$($ServicePrincipal.Count))"
        $selectedIndex = 0
        if ([int]::TryParse($selection, [ref]$selectedIndex) -and $selectedIndex -ge 1 -and $selectedIndex -le $ServicePrincipal.Count) {
            return $ServicePrincipal[$selectedIndex - 1]
        }
        Write-Host "Invalid selection. Please enter a number between 1 and $($ServicePrincipal.Count)." -ForegroundColor Yellow
    }
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

# Find the enterprise app (Service Principal), either by ID (unique) or by display name (may match several)
if ($PSCmdlet.ParameterSetName -eq 'ById') {
    Write-Host "Searching for enterprise app with Id: $EnterpriseAppId" -ForegroundColor Cyan

    # The supplied Id can be either the application (client) Id or the Service Principal object Id.
    $matchedApps = @(Get-MgServicePrincipal -Filter "appId eq '$EnterpriseAppId'" -ErrorAction SilentlyContinue)
    if ($matchedApps.Count -eq 0) {
        # Not an application (client) Id - fall back to a direct object Id lookup.
        $matchedApps = @(Get-MgServicePrincipal -ServicePrincipalId $EnterpriseAppId -ErrorAction SilentlyContinue)
    }
    if ($matchedApps.Count -eq 0) {
        Write-Host "No enterprise app found with application Id or object Id '$EnterpriseAppId'." -ForegroundColor Red
        exit 1
    }

    # Both lookups are on unique keys, so exactly one app is returned.
    $sp = $matchedApps[0]
}
else {
    Write-Host "Searching for enterprise app: $EnterpriseAppName" -ForegroundColor Cyan

    # Escape single quotes so the value is safe to embed in the OData filter.
    $escapedAppName = $EnterpriseAppName.Replace("'", "''")

    # startsWith returns exact duplicates as well as close matches, so the user can confirm the right app.
    # Advanced query (ConsistencyLevel/CountVariable) is required for startsWith on servicePrincipals.
    $matchedApps = @(Get-MgServicePrincipal -Filter "startsWith(displayName, '$escapedAppName')" -ConsistencyLevel eventual -CountVariable appCount -Sort "displayName" -All)
    if ($matchedApps.Count -eq 0) {
        Write-Host "Enterprise app '$EnterpriseAppName' not found." -ForegroundColor Red
        exit 1
    }

    $sp = Select-ServicePrincipal -ServicePrincipal $matchedApps
}
Write-Host "Using app: $($sp.DisplayName) (AppId: $($sp.AppId), ObjectId: $($sp.Id))" -ForegroundColor Green

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
