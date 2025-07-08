# Import required modules
Import-Module ActiveDirectory
Import-Module Microsoft.Graph.Groups

# Connect to Microsoft Graph (interactive login)
Connect-MgGraph -Scopes "Group.Read.All"

# Get all groups from on-prem AD
$adGroups = Get-ADGroup -Filter * -Properties objectSid, mail, GroupCategory, GroupScope, SamAccountName, Name

# Prepare results array
$results = @()

foreach ($adGroup in $adGroups) {
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

# Export to CSV
$results | Export-Csv -Path ".\AD_Groups_Entra_Report.csv" -NoTypeInformation -Encoding UTF8

Write-Host "Report generated: AD_Groups_Entra_Report.csv" 