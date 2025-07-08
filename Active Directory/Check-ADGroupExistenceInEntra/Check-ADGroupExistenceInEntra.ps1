# Import required modules
Import-Module ActiveDirectory
Import-Module Microsoft.Graph.Groups

param(
    [Parameter(Mandatory = $true)]
    [string]$DCHostName
)

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
$connectionTest = Test-NetConnection -ComputerName $DCHostName -Port 5986
if (-not $connectionTest.TcpTestSucceeded) {
    Write-Host "Cannot connect to $DCHostName on port 5986 (WinRM over SSL). Please check connectivity and WinRM configuration." -ForegroundColor Red
    exit 1
}

# Prompt for domain admin credentials and create a PSSession over SSL
$domainCred = Get-Credential -Message "Enter domain admin credentials for $DCHostName"
$session = New-PSSession -ComputerName $DCHostName -Credential $domainCred -UseSSL



# Import AD module from remote session
Import-PSSession -Session $session -Module ActiveDirectory -AllowClobber | Out-Null

# Connect to Microsoft Graph (interactive login)
Connect-MgGraph -Scopes "Group.Read.All"

# Get all groups from on-prem AD via the imported session (now local)
$adGroups = Get-ADGroup -Filter * -Properties objectSid, mail, GroupCategory, GroupScope, SamAccountName, Name

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