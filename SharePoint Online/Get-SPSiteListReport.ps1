<#
.SYNOPSIS
This script generates a report for all SharePoint sites on the given tenant.
.DESCRIPTION
This script connects to SharePoint Online and generates a report for all sites.
.PARAMETER appClientID
The client ID of the app registration used to authenticate with SharePoint Online.
.PARAMETER tenant
The tenant name used to authenticate with SharePoint Online.
.PARAMETER CertThumbprint
The thumbprint of the certificate used to authenticate with SharePoint Online.
.PARAMETER SPAdminURL
The URL of the SharePoint Admin site used to authenticate with SharePoint Online.
.OUTPUTS
This script generates two CSV files:
1. SharePointSiteListReport.csv - This file contains the report for all SharePoint sites.
2. SharePointSiteListReport_$currentDate.csv - This file contains the report for all SharePoint sites for the current date.
.EXAMPLE
.\Get-SPSiteListReport.ps1 -appClientID "xxxxxxxx-xxxx-xxxx-xxxx-xxxxxxxxxxxx" -tenant "contoso" -CertThumbprint "xxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxxx" -SPAdminURL "XXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXXX"
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

#Define the arrays to store the final results
$listFinalResult = @()
$siteFinalResult = @()
$currentDate = Get-Date -Format "yyyyMMdd"

#Connect to SharePoint Online using app-only authentication
#This connection uses the client ID and thumbprint of the certificate to authenticate
Connect-PnPOnline $SPAdminURL -ClientId $AppClientID -Tenant $TenantURL -Thumbprint $CertThumbprint

#Get all site collections
#Filter out the ones that are OneDrive for Business or SharePoint Admin sites
$SiteCollections = Get-PnPTenantSite | Where-Object {$_.Url -notlike "*-my.sharepoint.com*" -and $_.Url -notlike "*-admin.sharepoint.com*"}



foreach ($Site in $SiteCollections) {
      $SiteURL = $Site.Url

      #Output the current site being processed
      Write-Host "Processing site: $SiteURL" -ForegroundColor Green

      #Connect to the individual site
      $SiteConnection = Connect-PnPOnline -Tenant $TenantURL -Url $SiteURL -ClientId $AppClientID -Thumbprint $CertThumbprint -ReturnConnection
      #Get the data for the site
      $siteData = Get-PnPTenantSite -Identity $SiteURL
      #Get the recycle bin items for the site
      $recycleBinData = Get-PnPRecycleBinItem -Connection $SiteConnection
      #Sum up the size for all the recycle bin items
      $recycleBinSize = $recycleBinData | Measure-Object -Property Size -Sum | Select-Object -ExpandProperty Sum

      #Create a custom object to store the result of a single site
      $siteResultEntry = [PSCustomObject]@{
            Site = $SiteURL
            Title = $siteData.Title
            Description = $siteData.Description
            Owner = $siteData.OwnerName
            OwnerEmail = $siteData.OwnerEmail
            StorageUsageInGB = [Math]::Round($siteData.StorageUsageCurrent / 1KB,2)
            StorageQuotaInGB = [Math]::Round($siteData.StorageQuota / 1KB,2)
            RecycleBinSizeInGB = [Math]::Round($recycleBinSize / 1MB,2)
            LastContentModifiedDate = $siteData.LastContentModifiedDate
      }


      #Get all lists with versioning enabled
      #Filter out the ones that are not document libraries or generic lists
      $SiteLists=  Get-PnPList -Connection $SiteConnection | Where-Object {$_.EnableVersioning -eq $True -and ($_.BaseType -eq 'DocumentLibrary' -or $_.BaseType -eq 'GenericList')} -ErrorAction SilentlyContinue
      foreach ($List in $SiteLists) {
            #Create a custom object to store the result of a single list
            #This object will contain the site URL, list title, and versioning information
            #The object will be added to the final result array
            $listResultEntry = [PSCustomObject]@{
                  # Below item is to display the site URL
                  Site = $SiteURL
                  # Below items are to display each list under the above site
                  AccessURL = "https://fshr.sharepoint.com" + $List.DefaultViewUrl
                  ListTitle = $List.Title
                  EnableVersioning = $List.EnableVersioning
                  ObjectVersion = $List.ObjectVersion
                  MajorVersionLimit = $List.MajorVersionLimit
            }
            # Add the result entry to the final result array
            $listFinalResult += $listResultEntry
      }

      $siteFinalResult += $siteResultEntry
}

#Export the final results to CSV files
$siteFinalResult | Export-Csv -Path "./SharePointSiteReport-$currentDate.csv" -NoTypeInformation -Encoding UTF8
$listFinalResult | Export-Csv -Path "./SharePointListReport-$currentDate.csv" -NoTypeInformation -Encoding UTF8

#Disconnect from SharePoint Online
Disconnect-PnPOnline