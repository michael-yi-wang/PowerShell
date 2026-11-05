<#
.SYNOPSIS
    Lists the users assigned a selected license and shows whether each assignment is direct or
    inherited from a group.

.DESCRIPTION
    The script connects to Microsoft Graph, lists every license (subscribed SKU) in the tenant and
    prompts the operator to select one. It then retrieves all users assigned that license, works out
    how each user received it, and exports the result to CSV in the "output" folder next to the script.

    The export has one row per user:

      - AssignmentType is "Direct", "Group", or "Direct and Group".
      - GroupName holds the assigning group. Several groups are separated by "; ".
      - Assignments in the "Error" state are ignored, because they did not grant the license.
      - AssignmentType is "Unknown" if Graph returned no usable assignment state for the user.

    All Graph calls are made with Invoke-MgGraphRequest, so only Microsoft.Graph.Authentication is needed.

.PARAMETER TenantId
    Tenant to connect to (GUID or domain).

.EXAMPLE
    .\Get-LicensedUser.ps1 -TenantId "contoso.onmicrosoft.com"

    Connects to the tenant, prompts for a license and exports its users to
    .\output\LicensedUser_<SkuPartNumber>_<timestamp>.csv.

.NOTES
    Author      : Michael
    Date        : 2026-11-05
    Requirements: PowerShell 7+, Microsoft.Graph.Authentication module
    Permissions : LicenseAssignment.Read.All, User.Read.All, Group.ReadBasic.All (delegated)
    Roles       : Global Reader or Directory Readers, or equivalent.

    References:
      - List subscribedSkus:
        https://learn.microsoft.com/graph/api/subscribedsku-list?view=graph-rest-1.0
      - Filter users by assigned license:
        https://learn.microsoft.com/graph/filter-query-parameter#filter-using-lambda-operators
      - licenseAssignmentState resource type:
        https://learn.microsoft.com/graph/api/resources/licenseassignmentstate?view=graph-rest-1.0
      - Get group:
        https://learn.microsoft.com/graph/api/group-get?view=graph-rest-1.0
#>

#Requires -Version 7.0
#Requires -Modules Microsoft.Graph.Authentication

[CmdletBinding()]
param (
    [Parameter(Mandatory = $true)]
    [ValidateNotNullOrEmpty()]
    [string]$TenantId
)

$ErrorActionPreference = 'Stop'

# --- Logging ---
$timestamp = Get-Date -Format 'yyyyMMdd_HHmmss'
$scriptName = 'Get-LicensedUser'
$logFile = Join-Path $PSScriptRoot "${scriptName}_$timestamp.log"

function Write-Log {
    param (
        [string]$Message,
        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )
    $entry = "[$(Get-Date -Format 'yyyy-MM-dd HH:mm:ss')] [$Level] $Message"
    Add-Content -Path $logFile -Value $entry
    switch ($Level) {
        'Info'    { Write-Host $entry -ForegroundColor Green }
        'Warning' { Write-Host $entry -ForegroundColor Yellow }
        'Error'   { Write-Host $entry -ForegroundColor Red }
    }
}

# --- Helpers ---

# Follows @odata.nextLink and emits every item of a Graph collection
function Get-GraphCollection {
    param ([string]$Uri)
    while ($Uri) {
        $response = Invoke-MgGraphRequest -Method GET -Uri $Uri -OutputType PSObject
        if ($response.value) { $response.value }
        $Uri = $response.'@odata.nextLink'
    }
}

# Shows a numbered license menu and returns the selected SKU, or $null if the operator quits
function Select-License {
    param ([object[]]$Licenses)

    Write-Host ''
    Write-Host ('{0,4}  {1,-45} {2,10} {3,10}' -f '#', 'License', 'Assigned', 'Purchased') -ForegroundColor Cyan
    for ($i = 0; $i -lt $Licenses.Count; $i++) {
        $sku = $Licenses[$i]
        Write-Host ('{0,4}  {1,-45} {2,10} {3,10}' -f ($i + 1), $sku.skuPartNumber, $sku.consumedUnits, $sku.prepaidUnits.enabled)
    }
    Write-Host ''

    while ($true) {
        $answer = (Read-Host "Select a license (1-$($Licenses.Count), or Q to quit)").Trim()
        if ($answer -eq 'Q') { return $null }

        $number = 0
        if ([int]::TryParse($answer, [ref]$number) -and $number -ge 1 -and $number -le $Licenses.Count) {
            return $Licenses[$number - 1]
        }
        Write-Host "'$answer' is not a valid selection." -ForegroundColor Yellow
    }
}

# Returns a group's display name, calling Graph once per group. Falls back to the group ID so the
# export still identifies the group when it cannot be read.
function Get-GroupName {
    param ([string]$GroupId)

    if (-not $groupNames.ContainsKey($GroupId)) {
        try {
            $group = Invoke-MgGraphRequest -Method GET -Uri "v1.0/groups/$GroupId`?`$select=displayName" -OutputType PSObject
            $groupNames[$GroupId] = $group.displayName
        }
        catch {
            Write-Log "Could not read group $GroupId, using its ID as the group name: $($_.Exception.Message)" -Level Warning
            $groupNames[$GroupId] = $GroupId
        }
    }
    $groupNames[$GroupId]
}

# Builds the export row for one user from the assignment states of the selected SKU
function ConvertTo-LicensedUserRow {
    param (
        [object]$User,
        [string]$SkuId
    )

    $isDirect = $false
    $isUnresolved = $true
    $groupIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::OrdinalIgnoreCase)

    # A user has one state per assignment, so the same SKU can appear more than once
    foreach ($state in $User.licenseAssignmentStates) {
        if ($state.skuId -ne $SkuId -or $state.state -eq 'Error') { continue }

        $isUnresolved = $false
        if ($state.assignedByGroup) {
            [void]$groupIds.Add($state.assignedByGroup)
        }
        else {
            $isDirect = $true
        }
    }

    $assignmentType = if ($isUnresolved) { 'Unknown' }
    elseif ($isDirect -and $groupIds.Count) { 'Direct and Group' }
    elseif ($isDirect) { 'Direct' }
    else { 'Group' }

    [PSCustomObject]@{
        FirstName      = $User.givenName
        LastName       = $User.surname
        DisplayName    = $User.displayName
        Email          = $User.mail
        Title          = $User.jobTitle
        OfficeLocation = $User.officeLocation
        AssignmentType = $assignmentType
        GroupName      = (@($groupIds | ForEach-Object { Get-GroupName -GroupId $_ }) | Sort-Object) -join '; '
    }
}

# --- Main ---
$requiredScopes = @('LicenseAssignment.Read.All', 'User.Read.All', 'Group.ReadBasic.All')
$groupNames = @{}
$connected = $false

try {
    Write-Log "Connecting to Microsoft Graph (tenant $TenantId)."
    Connect-MgGraph -TenantId $TenantId -Scopes $requiredScopes -NoWelcome
    $connected = $true

    $licenses = @(Get-GraphCollection -Uri 'v1.0/subscribedSkus?$select=skuId,skuPartNumber,consumedUnits,prepaidUnits' |
        Sort-Object -Property skuPartNumber)
    if (-not $licenses) {
        Write-Log 'No licenses were found in this tenant.' -Level Warning
        return
    }
    Write-Log "Found $($licenses.Count) license(s)."

    $license = Select-License -Licenses $licenses
    if (-not $license) {
        Write-Log 'No license selected. Exiting.' -Level Warning
        return
    }
    Write-Log "Selected license: $($license.skuPartNumber) ($($license.skuId))."

    # licenseAssignmentStates is returned only when it is named in $select
    $filter = [uri]::EscapeDataString("assignedLicenses/any(s:s/skuId eq $($license.skuId))")
    $select = 'givenName,surname,displayName,mail,jobTitle,officeLocation,licenseAssignmentStates'
    $users = Get-GraphCollection -Uri "v1.0/users?`$filter=$filter&`$select=$select&`$top=999"

    $results = [System.Collections.Generic.List[object]]::new()
    foreach ($user in $users) {
        $results.Add((ConvertTo-LicensedUserRow -User $user -SkuId $license.skuId))
    }

    if ($results.Count -eq 0) {
        Write-Log "No users are assigned $($license.skuPartNumber). No CSV was created." -Level Warning
        return
    }

    $unknownCount = @($results | Where-Object AssignmentType -EQ 'Unknown').Count
    if ($unknownCount) {
        Write-Log "$unknownCount user(s) have no usable assignment state and are marked Unknown." -Level Warning
    }

    $outputFolder = Join-Path $PSScriptRoot 'output'
    New-Item -Path $outputFolder -ItemType Directory -Force | Out-Null

    $safeName = $license.skuPartNumber -replace '[^\w\-]', '_'
    $outputFile = Join-Path $outputFolder "LicensedUser_${safeName}_$timestamp.csv"
    $results | Sort-Object -Property DisplayName | Export-Csv -Path $outputFile -NoTypeInformation -Encoding utf8BOM

    foreach ($type in ($results | Group-Object -Property AssignmentType | Sort-Object -Property Name)) {
        Write-Log "$($type.Name): $($type.Count) user(s)."
    }
    Write-Log "Exported $($results.Count) user(s) to $outputFile."
}
catch {
    Write-Log "Script failed: $($_.Exception.Message)" -Level Error
    exit 1
}
finally {
    if ($connected) {
        Disconnect-MgGraph | Out-Null
        Write-Log 'Disconnected from Microsoft Graph.'
    }
}
