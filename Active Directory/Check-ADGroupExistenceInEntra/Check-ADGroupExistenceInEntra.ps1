# Check if machine is domain-joined
$computerSystem = Get-WmiObject -Class Win32_ComputerSystem
if (-not $computerSystem.PartOfDomain) {
    Write-Host "This script must be run on a domain-joined machine. Aborting." -ForegroundColor Red
    exit 1
}

# List available domain controllers and prompt user to select one
$domainControllers = Get-ADDomainController -Filter *
$dcList = $domainControllers | Select-Object -Property Name, HostName
Write-Host "Available Domain Controllers:" -ForegroundColor Cyan
for ($i = 0; $i -lt $dcList.Count; $i++) {
    Write-Host ("[{0}] {1} ({2})" -f $i, $dcList[$i].Name, $dcList[$i].HostName)
}
$selectedIndex = Read-Host "Enter the number of the DC to use"
if ($selectedIndex -notmatch '^[0-9]+$' -or $selectedIndex -ge $dcList.Count) {
    Write-Host "Invalid selection. Aborting." -ForegroundColor Red
    exit 1
}
$selectedDC = $dcList[$selectedIndex].HostName

# Prompt for domain admin credentials and create a PSSession
$domainCred = Get-Credential -Message "Enter domain admin credentials for $selectedDC"
$session = New-PSSession -ComputerName $selectedDC -Credential $domainCred

# Import required modules
Import-Module ActiveDirectory
Import-Module Microsoft.Graph.Groups

# Connect to Microsoft Graph (interactive login)
Connect-MgGraph -Scopes "Group.Read.All"

# Get all groups from on-prem AD via the selected DC
$adGroups = Invoke-Command -Session $session -ScriptBlock {
    Get-ADGroup -Filter * -Properties objectSid, mail, GroupCategory, GroupScope, SamAccountName, Name
}

# Prepare results array
$results = @()

for ($idx = 0; $idx -lt $adGroups.Count; $idx++) {
    $adGroup = $adGroups[$idx]
    $percentComplete = [int](($idx / $adGroups.Count) * 100)
    Write-Progress -Activity "Processing AD Groups" -Status ("Processing {0} of {1}" -f ($idx+1), $adGroups.Count) -PercentComplete $percentComplete

    $onPremSid = $adGroup.objectSid.Value
    $groupType = if ($adGroup.GroupCategory -eq "Distribution") { "Distribution Group" } else { "Security group" }
    $groupEmail = $adGroup.mail

    # Search for group in Entra ID by onPremisesSecurityIdentifier
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