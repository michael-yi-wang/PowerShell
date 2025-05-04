<#
.SYNOPSIS
This script changes the file version for all SharePoint sites.
.DESCRIPTION
This script connects to SharePoint Online and changes the file version for all sites.
It sets the MajorVersionLimit to 100 for all lists with versioning enabled.
The script will only target site that has type of STS, TEAMCHANNEL, or GROUP.
.PARAMETER AppClientID
The client ID of the app registration used to authenticate with SharePoint Online.
.PARAMETER TenantURL
The tenant name used to authenticate with SharePoint Online.
.PARAMETER CertThumbprint
The thumbprint of the certificate used to authenticate with SharePoint Online.
.PARAMETER SPAdminURL
The URL of the SharePoint Admin site used to authenticate with SharePoint Online.
.OUTPUTS
This script generates a CSV file:
1. SharePointSiteVersionChangeReport.csv - This file contains the report for all SharePoint sites.
.EXAMPLE
.\Change-SPListVersion.ps1 -AppClientID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -TenantURL "contoso" -CertThumbprint "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" -SPAdminURL "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
#>
[CmdletBinding()]
param (
      [Parameter(Mandatory=$true)]
      [string]$AppClientID,
      [Parameter(Mandatory=$true)]
      [string]$TenantURL,
      [Parameter(Mandatory=$true)]
      [string]$CertThumbprint,
      [Parameter(Mandatory=$true)]
      [string]$SPAdminURL
)

#Check if PnP PowerShell module is installed
if (!(Get-InstalledModule PnP.PowerShell -ErrorAction SilentlyContinue)) {
      # Install PowerShell Module
      Install-Module PnP.PowerShell -Scope CurrentUser -Force -AllowClobber
}
#Import the PnP PowerShell module
#This module is used to connect to SharePoint Online and perform various operations
Import-Module PnP.PowerShell

Connect-PnPOnline $SPAdminURL -ClientId $AppClientID -Tenant $TenantURL -Thumbprint $CertThumbprint

#Get all site collections
#Filter out the ones that are not team sites or group sites
$SiteCollections = Get-PnPTenantSite | Where-Object {($_.template -like "STS*" -or $_.template -like "TEAMCHANNEL*" -or $_.template -like "GROUP*") -and $_.Url -notlike "*-my.sharepoint.com*" -and $_.Url -notlike "*-admin.sharepoint.com*"}
$FinalResult = @()
$count = 1

Write-Host "Found $($SiteCollections.Count) sites." -ForegroundColor Green

foreach ($Site in $SiteCollections) {
      $SiteURL = $Site.Url
      Write-Host "$count \ $($SiteCollections.Count) Processing site: $SiteURL" -ForegroundColor Green
      #Connect to the individual site
      $SiteConnection = Connect-PnPOnline -Tenant $TenantURL -Url $SiteURL -ClientId $AppClientID -Thumbprint $CertThumbprint -ReturnConnection
      #Get all lists with versioning enabled
      #Filter out the ones that are not document libraries or generic lists
      $SiteLists=  Get-PnPList -Connection $SiteConnection | Where-Object {$_.EnableVersioning -eq $True -and ($_.BaseType -eq 'DocumentLibrary' -or $_.BaseType -eq 'GenericList')} -ErrorAction SilentlyContinue
      foreach ($List in $SiteLists) {
            # Only process lists with MajorVersionLimit >= 100
            if ($List.MajorVersionLimit -ge 100 ) {
                  # Set the MajorVersionLimit to 100
                  Set-PnPList -Identity $List.Id -Connection $SiteConnection -MajorVersions 100 -ErrorAction SilentlyContinue | Out-Null
                  # Create a custom object to store the result
                  $ResultEntry = [PSCustomObject]@{
                        # Below item is to display the site URL
                        Site = $SiteURL
                        # Below items are to display each list under the above site
                        AccessURL = $SPAdminURL + $List.DefaultViewUrl
                        ListTitle = $List.Title
                  }
                  # Add the result entry to the final result array
                  $FinalResult += $ResultEntry
            }

      }
      $count++
}
# Export the final result to a CSV file
$FinalResult | Export-Csv -Path ./SharePointSiteVersionChangeReport.csv -NoTypeInformation -Encoding UTF8
Disconnect-PnPOnline