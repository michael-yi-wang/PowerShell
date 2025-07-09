param(
    [Parameter(Mandatory=$true)]
    [string]$OnPremCsvPath,
    [Parameter(Mandatory=$true)]
    [string]$EntraCsvPath,
    [Parameter(Mandatory=$true)]
    [string]$OutputCsvPath
)

# Import CSVs
$onPremGroups = Import-Csv -Path $OnPremCsvPath
$entraGroups = Import-Csv -Path $EntraCsvPath

# Create a hashtable for fast lookup of Entra groups by OnPremisesSecurityIdentifier
$entraHash = @{}
foreach ($entra in $entraGroups) {
    if ($entra.OnPremisesSecurityIdentifier) {
        $entraHash[$entra.OnPremisesSecurityIdentifier] = $entra
    }
}

# Prepare output
$output = foreach ($onPrem in $onPremGroups) {
    $sid = $onPrem.SID
    $entra = $null
    $existInEntra = $false
    $entraGroupName = ""
    $entraGroupID = ""

    if ($sid -and $entraHash.ContainsKey($sid)) {
        $entra = $entraHash[$sid]
        $existInEntra = $true
        $entraGroupName = $entra.DisplayName
        $entraGroupID = $entra.Id
    }

    [PSCustomObject]@{
        OnPremGroupName   = $onPrem.'Group Name'
        OnPremGroupType   = $onPrem.'Group Type(String)'
        OnPremGroupEmail  = $onPrem.Email
        OnPremGroupSID    = $sid
        ExistInEntra      = $existInEntra
        EntraGroupName    = $entraGroupName
        EntraGroupID      = $entraGroupID
    }
}

# Export to CSV
$output | Export-Csv -Path $OutputCsvPath -NoTypeInformation -Encoding UTF8

Write-Host "Comparison complete. Output saved to $OutputCsvPath" 