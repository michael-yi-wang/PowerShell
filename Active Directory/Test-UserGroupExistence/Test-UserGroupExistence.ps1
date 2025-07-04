<#
.SYNOPSIS
    Checks if users and groups from a CSV file exist in both on-premises Active Directory and Azure AD.

.DESCRIPTION
    This script reads user and group objects from a CSV file and verifies their existence in both
    on-premises Active Directory and Azure AD (Entra ID). It provides detailed reporting on the
    existence status of each object.

.PARAMETER CsvPath
    The path to the CSV file containing user and group objects to check.

.PARAMETER ObjectTypeColumn
    The name of the column in the CSV that indicates whether the object is a user or group.
    Default is "ObjectType".

.PARAMETER NameColumn
    The name of the column in the CSV that contains the user/group names to check.
    Default is "Name".

.PARAMETER OutputPath
    The path where the results will be exported as a CSV file.
    Default is "UserGroupExistenceReport.csv" in the current directory.

.PARAMETER ConnectToAzureAD
    Switch parameter to connect to Azure AD. If not specified, the script will attempt to
    use existing connections.

.EXAMPLE
    .\Test-UserGroupExistence.ps1 -CsvPath "C:\Users\Administrator\Desktop\users_groups.csv"

.EXAMPLE
    .\Test-UserGroupExistence.ps1 -CsvPath "C:\Users\Administrator\Desktop\users_groups.csv" -ConnectToAzureAD

.NOTES
    Author: PowerShell Script
    Date: $(Get-Date -Format "yyyy-MM-dd")
    Version: 1.0
    
    Requirements:
    - Active Directory PowerShell module
    - Azure AD PowerShell module (if checking Azure AD)
    - Appropriate permissions to query both on-premises AD and Azure AD
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the CSV file containing user and group objects")]
    [string]$CsvPath,
    
    [Parameter(Mandatory = $false, HelpMessage = "Name of the column indicating object type (User/Group)")]
    [string]$ObjectTypeColumn = "ObjectType",
    
    [Parameter(Mandatory = $false, HelpMessage = "Name of the column containing user/group names")]
    [string]$NameColumn = "Name",
    
    [Parameter(Mandatory = $false, HelpMessage = "Path for the output CSV report")]
    [string]$OutputPath = "UserGroupExistenceReport.csv",
    
    [Parameter(Mandatory = $false, HelpMessage = "Connect to Azure AD if not already connected")]
    [switch]$ConnectToAzureAD
)

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to check if a user exists in on-premises AD
function Test-OnPremUserExists {
    param([string]$UserName)
    
    try {
        $user = Get-ADUser -Identity $UserName -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# Function to check if a group exists in on-premises AD
function Test-OnPremGroupExists {
    param([string]$GroupName)
    
    try {
        $group = Get-ADGroup -Identity $GroupName -ErrorAction Stop
        return $true
    }
    catch {
        return $false
    }
}

# Function to check if a user exists in Azure AD
function Test-AzureUserExists {
    param([string]$UserName)
    
    try {
        $user = Get-AzureADUser -ObjectId $UserName -ErrorAction Stop
        return $true
    }
    catch {
        try {
            # Try searching by UserPrincipalName
            $user = Get-AzureADUser -SearchString $UserName -ErrorAction Stop
            if ($user) { return $true }
        }
        catch {
            # Try searching by DisplayName
            try {
                $user = Get-AzureADUser -All $true | Where-Object { $_.DisplayName -eq $UserName }
                if ($user) { return $true }
            }
            catch {
                return $false
            }
        }
        return $false
    }
}

# Function to check if a group exists in Azure AD
function Test-AzureGroupExists {
    param([string]$GroupName)
    
    try {
        $group = Get-AzureADGroup -ObjectId $GroupName -ErrorAction Stop
        return $true
    }
    catch {
        try {
            # Try searching by DisplayName
            $group = Get-AzureADGroup -SearchString $GroupName -ErrorAction Stop
            if ($group) { return $true }
        }
        catch {
            return $false
        }
        return $false
    }
}

# Main script execution
try {
    Write-ColorOutput "=== User and Group Existence Checker ===" "Cyan"
    Write-ColorOutput "Script started at: $(Get-Date)" "Yellow"
    
    # Check if CSV file exists
    if (-not (Test-Path $CsvPath)) {
        throw "CSV file not found at: $CsvPath"
    }
    
    Write-ColorOutput "Reading CSV file: $CsvPath" "Green"
    
    # Import CSV file
    $csvData = Import-Csv -Path $CsvPath -ErrorAction Stop
    Write-ColorOutput "Successfully imported $($csvData.Count) objects from CSV" "Green"
    
    # Validate CSV structure
    if (-not $csvData[0].PSObject.Properties.Name.Contains($ObjectTypeColumn)) {
        throw "Column '$ObjectTypeColumn' not found in CSV file. Available columns: $($csvData[0].PSObject.Properties.Name -join ', ')"
    }
    
    if (-not $csvData[0].PSObject.Properties.Name.Contains($NameColumn)) {
        throw "Column '$NameColumn' not found in CSV file. Available columns: $($csvData[0].PSObject.Properties.Name -join ', ')"
    }
    
    # Check Active Directory module
    Write-ColorOutput "Checking Active Directory PowerShell module..." "Yellow"
    if (-not (Get-Module -ListAvailable -Name ActiveDirectory)) {
        throw "Active Directory PowerShell module is not installed. Please install RSAT tools."
    }
    
    Import-Module ActiveDirectory -ErrorAction Stop
    Write-ColorOutput "Active Directory module loaded successfully" "Green"
    
    # Check Azure AD connection
    Write-ColorOutput "Checking Azure AD connection..." "Yellow"
    $azureConnected = $false
    
    try {
        $context = Get-AzureADCurrentSessionInfo -ErrorAction Stop
        if ($context) {
            Write-ColorOutput "Already connected to Azure AD" "Green"
            $azureConnected = $true
        }
    }
    catch {
        Write-ColorOutput "Not connected to Azure AD" "Yellow"
    }
    
    # Connect to Azure AD if needed
    if (-not $azureConnected) {
        if ($ConnectToAzureAD) {
            Write-ColorOutput "Connecting to Azure AD..." "Yellow"
            try {
                Connect-AzureAD -ErrorAction Stop
                Write-ColorOutput "Successfully connected to Azure AD" "Green"
                $azureConnected = $true
            }
            catch {
                Write-ColorOutput "Failed to connect to Azure AD. Azure AD checks will be skipped." "Red"
                $azureConnected = $false
            }
        }
        else {
            Write-ColorOutput "Not connected to Azure AD. Use -ConnectToAzureAD parameter to connect." "Yellow"
            Write-ColorOutput "Azure AD checks will be skipped." "Yellow"
        }
    }
    
    # Initialize results array
    $results = @()
    $processedCount = 0
    
    Write-ColorOutput "Starting existence checks..." "Cyan"
    Write-ColorOutput "Progress: " -NoNewline
    
    # Process each object in the CSV
    foreach ($object in $csvData) {
        $processedCount++
        $progress = [math]::Round(($processedCount / $csvData.Count) * 100, 1)
        Write-Progress -Activity "Checking object existence" -Status "Processing $processedCount of $($csvData.Count)" -PercentComplete $progress
        
        $objectName = $object.$NameColumn
        $objectType = $object.$ObjectTypeColumn
        
        # Initialize result object
        $result = [PSCustomObject]@{
            Name = $objectName
            ObjectType = $objectType
            OnPremExists = $null
            AzureExists = $null
            OnPremDetails = ""
            AzureDetails = ""
            Timestamp = Get-Date
        }
        
        # Check on-premises AD
        try {
            if ($objectType -eq "User" -or $objectType -eq "user") {
                $onPremExists = Test-OnPremUserExists -UserName $objectName
                $result.OnPremExists = $onPremExists
                $result.OnPremDetails = if ($onPremExists) { "User found in on-premises AD" } else { "User not found in on-premises AD" }
            }
            elseif ($objectType -eq "Group" -or $objectType -eq "group") {
                $onPremExists = Test-OnPremGroupExists -GroupName $objectName
                $result.OnPremExists = $onPremExists
                $result.OnPremDetails = if ($onPremExists) { "Group found in on-premises AD" } else { "Group not found in on-premises AD" }
            }
            else {
                $result.OnPremDetails = "Invalid object type specified"
            }
        }
        catch {
            $result.OnPremDetails = "Error checking on-premises AD: $($_.Exception.Message)"
        }
        
        # Check Azure AD
        if ($azureConnected) {
            try {
                if ($objectType -eq "User" -or $objectType -eq "user") {
                    $azureExists = Test-AzureUserExists -UserName $objectName
                    $result.AzureExists = $azureExists
                    $result.AzureDetails = if ($azureExists) { "User found in Azure AD" } else { "User not found in Azure AD" }
                }
                elseif ($objectType -eq "Group" -or $objectType -eq "group") {
                    $azureExists = Test-AzureGroupExists -GroupName $objectName
                    $result.AzureExists = $azureExists
                    $result.AzureDetails = if ($azureExists) { "Group found in Azure AD" } else { "Group not found in Azure AD" }
                }
                else {
                    $result.AzureDetails = "Invalid object type specified"
                }
            }
            catch {
                $result.AzureDetails = "Error checking Azure AD: $($_.Exception.Message)"
            }
        }
        else {
            $result.AzureDetails = "Azure AD check skipped - not connected"
        }
        
        # Add result to array
        $results += $result
        
        # Display progress
        if ($processedCount % 10 -eq 0 -or $processedCount -eq $csvData.Count) {
            Write-Host "$progress% " -NoNewline
        }
    }
    
    Write-Host ""
    Write-Progress -Activity "Checking object existence" -Completed
    
    # Generate summary
    Write-ColorOutput "`n=== SUMMARY ===" "Cyan"
    
    $totalObjects = $results.Count
    $onPremFound = ($results | Where-Object { $_.OnPremExists -eq $true }).Count
    $onPremNotFound = ($results | Where-Object { $_.OnPremExists -eq $false }).Count
    $onPremErrors = ($results | Where-Object { $_.OnPremExists -eq $null }).Count
    
    Write-ColorOutput "Total objects processed: $totalObjects" "White"
    Write-ColorOutput "On-premises AD - Found: $onPremFound, Not Found: $onPremNotFound, Errors: $onPremErrors" "White"
    
    if ($azureConnected) {
        $azureFound = ($results | Where-Object { $_.AzureExists -eq $true }).Count
        $azureNotFound = ($results | Where-Object { $_.AzureExists -eq $false }).Count
        $azureErrors = ($results | Where-Object { $_.AzureExists -eq $null }).Count
        
        Write-ColorOutput "Azure AD - Found: $azureFound, Not Found: $azureNotFound, Errors: $azureErrors" "White"
        
        # Objects missing from either environment
        $missingFromOnPrem = ($results | Where-Object { $_.OnPremExists -eq $false }).Count
        $missingFromAzure = ($results | Where-Object { $_.AzureExists -eq $false }).Count
        $missingFromBoth = ($results | Where-Object { $_.OnPremExists -eq $false -and $_.AzureExists -eq $false }).Count
        
        Write-ColorOutput "Missing from On-premises AD: $missingFromOnPrem" "Yellow"
        Write-ColorOutput "Missing from Azure AD: $missingFromAzure" "Yellow"
        Write-ColorOutput "Missing from both: $missingFromBoth" "Red"
    }
    
    # Export results to CSV
    Write-ColorOutput "`nExporting results to: $OutputPath" "Green"
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -ErrorAction Stop
    Write-ColorOutput "Results exported successfully" "Green"
    
    # Display objects not found in either environment
    Write-ColorOutput "`n=== OBJECTS NOT FOUND ===" "Cyan"
    
    $notFoundObjects = $results | Where-Object { $_.OnPremExists -eq $false -or $_.AzureExists -eq $false }
    
    if ($notFoundObjects.Count -gt 0) {
        foreach ($obj in $notFoundObjects) {
            $status = @()
            if ($obj.OnPremExists -eq $false) { $status += "OnPrem" }
            if ($obj.AzureExists -eq $false) { $status += "Azure" }
            
            Write-ColorOutput "$($obj.Name) ($($obj.ObjectType)) - Missing from: $($status -join ', ')" "Red"
        }
    }
    else {
        Write-ColorOutput "All objects found in both environments!" "Green"
    }
    
    Write-ColorOutput "`nScript completed successfully at: $(Get-Date)" "Green"
    Write-ColorOutput "Check the CSV file for detailed results: $OutputPath" "Cyan"
}

catch {
    Write-ColorOutput "`nERROR: $($_.Exception.Message)" "Red"
    Write-ColorOutput "Stack Trace: $($_.ScriptStackTrace)" "Red"
    exit 1
}

finally {
    # Cleanup
    if (Get-Module ActiveDirectory) {
        Remove-Module ActiveDirectory -Force -ErrorAction SilentlyContinue
    }
} 