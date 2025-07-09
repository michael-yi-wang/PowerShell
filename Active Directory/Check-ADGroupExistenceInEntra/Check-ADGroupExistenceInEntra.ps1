<#
.SYNOPSIS
    Checks if on-premises Active Directory groups exist in Entra ID (Azure AD) by comparing on-prem AD groups to Entra groups using Microsoft Graph.

.DESCRIPTION
    This script connects to a specified domain controller using PowerShell Remoting over SSL, imports the Active Directory module from that DC, and compares all on-prem AD groups to Entra ID groups by onPremisesSecurityIdentifier. Results are exported to a CSV report.

.PARAMETER DCHostName
    The FQDN of the domain controller to connect to (must be accessible via WinRM over SSL/port 5986).

.NOTES
    Author: <Your Name>
    Date:   <Date>
    Requires: Microsoft.Graph.Groups module, WinRM over SSL enabled on the DC
    Example usage:
        .\Check-ADGroupExistenceInEntra.ps1 -DCHostName dc01.contoso.com
#>
param(
    [Parameter(Mandatory = $true)]
    [string]$DCHostName
)

# Import required modules
Import-Module Microsoft.Graph.Groups

# Check and install required modules if missing
# Only check/install Microsoft.Graph.Groups, no need to check ActiveDirectory module locally
if (-not (Get-Module -ListAvailable -Name "Microsoft.Graph.Groups")) {
    Write-Host "Module 'Microsoft.Graph.Groups' not found. Installing..." -ForegroundColor Yellow
    try {
        Install-Module -Name "Microsoft.Graph.Groups" -MinimumVersion "1.24.0" -Force -Scope CurrentUser -AllowClobber
    } catch {
        Write-Host "Failed to install module Microsoft.Graph.Groups. Aborting." -ForegroundColor Red
        exit 1
    }
}

# Check connectivity to the DC on WinRM SSL port (5986)
$connectionTest = Test-NetConnection -ComputerName $DCHostName -Port 5986 | Out-Null
if (-not $connectionTest.TcpTestSucceeded) {
    Write-Host "Cannot connect to $DCHostName on port 5986 (WinRM over SSL). Please check connectivity and WinRM configuration or switch to a different domain controller." -ForegroundColor Red
    exit 1
}

# Prompt for domain admin credentials and create a PSSession over SSL
$domainCred = Get-Credential -Message "Enter domain admin credentials for $DCHostName"
$session = New-PSSession -ComputerName $DCHostName -Credential $domainCred -UseSSL

# Import AD module from remote session
Import-PSSession -Session $session -Module ActiveDirectory -AllowClobber | Out-Null

# Get all groups from on-prem AD via the imported session
Write-Host "Retrieving AD groups from $DCHostName..." -ForegroundColor Green
$localAdGroups = Get-ADGroup -Filter * -Properties objectSid, mail, GroupCategory, GroupScope, SamAccountName, Name

# Parse AD groups data to local session (convert to simple objects)
<#
Write-Host "Parsing AD groups data..." -ForegroundColor Green
$localAdGroups = @()
foreach ($group in $adGroups) {
    $localAdGroups += [PSCustomObject]@{
        Name = $group.Name
        SamAccountName = $group.SamAccountName
        ObjectSid = $group.objectSid.Value
        Mail = $group.mail
        GroupCategory = $group.GroupCategory
        GroupScope = $group.GroupScope
    }
}
#>

# Clean up the imported session
Remove-PSSession $session

# Connect to Microsoft Graph locally
Write-Host "Connecting to Microsoft Graph..." -ForegroundColor Green
Connect-MgGraph -Scopes "Group.Read.All"

# Prepare results array
$results = @()

Write-Host "Comparing AD groups with Entra ID groups..." -ForegroundColor Green
for ($idx = 0; $idx -lt $localAdGroups.Count; $idx++) {
    $adGroup = $localAdGroups[$idx]
    $percentComplete = [int](($idx / $localAdGroups.Count) * 100)
    Write-Progress -Activity "Processing AD Groups" -Status ("Processing {0} of {1}" -f ($idx+1), $localAdGroups.Count) -PercentComplete $percentComplete

    $onPremSid = $adGroup.ObjectSid
    $groupType = if ($adGroup.GroupCategory -eq "Distribution") { "Distribution Group" } else { "Security group" }
    $groupEmail = $adGroup.Mail

    # Search for group in Entra ID by onPremisesSecurityIdentifier (locally)
    $entraGroup = Get-MgGroup -Filter "onPremisesSecurityIdentifier eq '$onPremSid'" -Property DisplayName, Id | Select-Object -First 1

    if ($entraGroup) {
        $existInEntra = "Yes"
        $entraDisplayName = $entraGroup.DisplayName
        $entraGroupId = $entraGroup.Id
    } else {
        $existInEntra = "No"
        $entraDisplayName = ""
        $entraGroupId = ""
    }

    $results += [PSCustomObject]@{
        OnPremDisplayName      = $adGroup.Name
        OnPremsAMAccountName   = $adGroup.SamAccountName
        OnPremObjectSid        = $onPremSid
        GroupType              = $groupType
        GroupEmail             = $groupEmail
        ExistInEntra           = $existInEntra
        EntraGroupDisplayName  = $entraDisplayName
        EntraGroupId           = $entraGroupId
    }
}
Write-Progress -Activity "Processing AD Groups" -Completed

# Export to CSV
$results | Export-Csv -Path ".\AD_Groups_Entra_Report.csv" -NoTypeInformation -Encoding UTF8

Write-Host "Report generated: AD_Groups_Entra_Report.csv" 

# Clean up session
if ($session) { Remove-PSSession $session } 