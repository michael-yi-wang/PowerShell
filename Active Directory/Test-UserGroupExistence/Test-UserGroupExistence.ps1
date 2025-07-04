<#
.SYNOPSIS
    Checks if users and groups from a CSV file exist in both on-premises Active Directory and Entra ID.

.DESCRIPTION
    This script reads user and group names from a CSV file and verifies their existence in both
    on-premises Active Directory and Entra ID. It automatically detects whether each name is a user
    or group and provides detailed reporting including DistinguishedName and ObjectId.

.PARAMETER CsvPath
    The path to the CSV file containing user and group names to check.

.PARAMETER NameColumn
    The name of the column in the CSV that contains the user/group names to check.
    Default is "Name".

.PARAMETER OutputPath
    The path where the results will be exported as a CSV file.
    Default is "UserGroupExistenceReport.csv" in the current directory.

.PARAMETER ConnectToGraph
    Switch parameter to connect to Microsoft Graph. If not specified, the script will attempt to
    use existing connections.

.EXAMPLE
    .\Test-UserGroupExistence.ps1 -CsvPath "C:\Users\Administrator\Desktop\names.csv"

.EXAMPLE
    .\Test-UserGroupExistence.ps1 -CsvPath "C:\Users\Administrator\Desktop\names.csv" -ConnectToGraph

.NOTES
    Author: PowerShell Script
    Date: $(Get-Date -Format "yyyy-MM-dd")
    Version: 3.0
    
    Requirements:
    - Active Directory PowerShell module
    - Microsoft Graph PowerShell module (if checking Entra ID)
    - Appropriate permissions to query both on-premises AD and Entra ID
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true, HelpMessage = "Path to the CSV file containing user and group names")]
    [string]$CsvPath,
    
    [Parameter(Mandatory = $false, HelpMessage = "Name of the column containing user/group names")]
    [string]$NameColumn = "Name",
    
    [Parameter(Mandatory = $false, HelpMessage = "Path for the output CSV report")]
    [string]$OutputPath = "UserGroupExistenceReport.csv",
    
    [Parameter(Mandatory = $false, HelpMessage = "Connect to Microsoft Graph if not already connected")]
    [switch]$ConnectToGraph
)

# Function to write colored output
function Write-ColorOutput {
    param(
        [string]$Message,
        [string]$Color = "White"
    )
    Write-Host $Message -ForegroundColor $Color
}

# Function to check if a user exists in on-premises AD and return DistinguishedName
function Test-OnPremUserExists {
    param([string]$UserName)
    
    try {
        $user = Get-ADUser -Identity $UserName -Properties DistinguishedName -ErrorAction Stop
        return @{
            Exists = $true
            DistinguishedName = $user.DistinguishedName
            ObjectType = "User"
        }
    }
    catch {
        return @{
            Exists = $false
            DistinguishedName = $null
            ObjectType = $null
        }
    }
}

# Function to check if a group exists in on-premises AD and return DistinguishedName
function Test-OnPremGroupExists {
    param([string]$GroupName)
    
    try {
        $group = Get-ADGroup -Identity $GroupName -Properties DistinguishedName -ErrorAction Stop
        return @{
            Exists = $true
            DistinguishedName = $group.DistinguishedName
            ObjectType = "Group"
        }
    }
    catch {
        return @{
            Exists = $false
            DistinguishedName = $null
            ObjectType = $null
        }
    }
}

# Function to detect and check if a name exists in on-premises AD (as user or group)
function Test-OnPremExists {
    param([string]$Name)
    
    # First try as user
    $userResult = Test-OnPremUserExists -UserName $Name
    if ($userResult.Exists) {
        return $userResult
    }
    
    # If not found as user, try as group
    $groupResult = Test-OnPremGroupExists -GroupName $Name
    if ($groupResult.Exists) {
        return $groupResult
    }
    
    # Not found as either
    return @{
        Exists = $false
        DistinguishedName = $null
        ObjectType = $null
    }
}

# Function to check if a user exists in Entra ID using Microsoft Graph and return ObjectId
function Test-EntraUserExists {
    param([string]$UserName)
    
    try {
        # Try searching by UserPrincipalName first
        $user = Get-MgUser -Filter "userPrincipalName eq '$UserName'" -ErrorAction Stop
        if ($user) {
            return @{
                Exists = $true
                ObjectId = $user.Id
                ObjectType = "User"
            }
        }
        
        # Try searching by DisplayName
        $user = Get-MgUser -Filter "displayName eq '$UserName'" -ErrorAction Stop
        if ($user) {
            return @{
                Exists = $true
                ObjectId = $user.Id
                ObjectType = "User"
            }
        }
        
        # Try searching by Mail
        $user = Get-MgUser -Filter "mail eq '$UserName'" -ErrorAction Stop
        if ($user) {
            return @{
                Exists = $true
                ObjectId = $user.Id
                ObjectType = "User"
            }
        }
        
        # If UserName looks like an ObjectId, try direct lookup
        if ($UserName -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
            try {
                $user = Get-MgUser -UserId $UserName -ErrorAction Stop
                return @{
                    Exists = $true
                    ObjectId = $user.Id
                    ObjectType = "User"
                }
            }
            catch {
                # ObjectId not found
            }
        }
        
        return @{
            Exists = $false
            ObjectId = $null
            ObjectType = $null
        }
    }
    catch {
        return @{
            Exists = $false
            ObjectId = $null
            ObjectType = $null
        }
    }
}

# Function to check if a group exists in Entra ID using Microsoft Graph and return ObjectId
function Test-EntraGroupExists {
    param([string]$GroupName)
    
    try {
        # Try searching by DisplayName
        $group = Get-MgGroup -Filter "displayName eq '$GroupName'" -ErrorAction Stop
        if ($group) {
            return @{
                Exists = $true
                ObjectId = $group.Id
                ObjectType = "Group"
            }
        }
        
        # Try searching by MailNickname (for mail-enabled groups)
        $group = Get-MgGroup -Filter "mailNickname eq '$GroupName'" -ErrorAction Stop
        if ($group) {
            return @{
                Exists = $true
                ObjectId = $group.Id
                ObjectType = "Group"
            }
        }
        
        # If GroupName looks like an ObjectId, try direct lookup
        if ($GroupName -match '^[0-9a-fA-F]{8}-([0-9a-fA-F]{4}-){3}[0-9a-fA-F]{12}$') {
            try {
                $group = Get-MgGroup -GroupId $GroupName -ErrorAction Stop
                return @{
                    Exists = $true
                    ObjectId = $group.Id
                    ObjectType = "Group"
                }
            }
            catch {
                # ObjectId not found
            }
        }
        
        return @{
            Exists = $false
            ObjectId = $null
            ObjectType = $null
        }
    }
    catch {
        return @{
            Exists = $false
            ObjectId = $null
            ObjectType = $null
        }
    }
}

# Function to detect and check if a name exists in Entra ID (as user or group)
function Test-EntraExists {
    param([string]$Name)
    
    # First try as user
    $userResult = Test-EntraUserExists -UserName $Name
    if ($userResult.Exists) {
        return $userResult
    }
    
    # If not found as user, try as group
    $groupResult = Test-EntraGroupExists -GroupName $Name
    if ($groupResult.Exists) {
        return $groupResult
    }
    
    # Not found as either
    return @{
        Exists = $false
        ObjectId = $null
        ObjectType = $null
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
    Write-ColorOutput "Successfully imported $($csvData.Count) names from CSV" "Green"
    
    # Validate CSV structure
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
    
    # Check Microsoft Graph connection
    Write-ColorOutput "Checking Microsoft Graph connection..." "Yellow"
    $graphConnected = $false
    
    try {
        $context = Get-MgContext -ErrorAction Stop
        if ($context) {
            Write-ColorOutput "Already connected to Microsoft Graph" "Green"
            $graphConnected = $true
        }
    }
    catch {
        Write-ColorOutput "Not connected to Microsoft Graph" "Yellow"
    }
    
    # Connect to Microsoft Graph if needed
    if (-not $graphConnected) {
        if ($ConnectToGraph) {
            Write-ColorOutput "Connecting to Microsoft Graph..." "Yellow"
            try {
                Connect-MgGraph -ErrorAction Stop
                Write-ColorOutput "Successfully connected to Microsoft Graph" "Green"
                $graphConnected = $true
            }
            catch {
                Write-ColorOutput "Failed to connect to Microsoft Graph. Entra ID checks will be skipped." "Red"
                Write-ColorOutput "Error: $($_.Exception.Message)" "Red"
                $graphConnected = $false
            }
        }
        else {
            Write-ColorOutput "Not connected to Microsoft Graph. Use -ConnectToGraph parameter to connect." "Yellow"
            Write-ColorOutput "Entra ID checks will be skipped." "Yellow"
        }
    }
    
    # Initialize results array
    $results = @()
    $processedCount = 0
    
    Write-ColorOutput "Starting existence checks..." "Cyan"
    Write-ColorOutput "Progress: " -NoNewline
    
    # Process each name in the CSV
    foreach ($row in $csvData) {
        $processedCount++
        $progress = [math]::Round(($processedCount / $csvData.Count) * 100, 1)
        Write-Progress -Activity "Checking object existence" -Status "Processing $processedCount of $($csvData.Count)" -PercentComplete $progress
        
        $objectName = $row.$NameColumn
        
        # Initialize result object
        $result = [PSCustomObject]@{
            Name = $objectName
            OnPremExists = $null
            EntraExists = $null
            OnPremObjectType = ""
            EntraObjectType = ""
            OnPremDistinguishedName = ""
            EntraObjectId = ""
            OnPremDetails = ""
            EntraDetails = ""
            Timestamp = Get-Date
        }
        
        # Check on-premises AD
        try {
            $onPremResult = Test-OnPremExists -Name $objectName
            $result.OnPremExists = $onPremResult.Exists
            $result.OnPremObjectType = $onPremResult.ObjectType
            $result.OnPremDistinguishedName = $onPremResult.DistinguishedName
            $result.OnPremDetails = if ($onPremResult.Exists) { 
                "$($onPremResult.ObjectType) found in on-premises AD" 
            } else { 
                "Not found in on-premises AD" 
            }
        }
        catch {
            $result.OnPremDetails = "Error checking on-premises AD: $($_.Exception.Message)"
        }
        
        # Check Entra ID
        if ($graphConnected) {
            try {
                $entraResult = Test-EntraExists -Name $objectName
                $result.EntraExists = $entraResult.Exists
                $result.EntraObjectType = $entraResult.ObjectType
                $result.EntraObjectId = $entraResult.ObjectId
                $result.EntraDetails = if ($entraResult.Exists) { 
                    "$($entraResult.ObjectType) found in Entra ID" 
                } else { 
                    "Not found in Entra ID" 
                }
            }
            catch {
                $result.EntraDetails = "Error checking Entra ID: $($_.Exception.Message)"
            }
        }
        else {
            $result.EntraDetails = "Entra ID check skipped - not connected"
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
    
    if ($graphConnected) {
        $entraFound = ($results | Where-Object { $_.EntraExists -eq $true }).Count
        $entraNotFound = ($results | Where-Object { $_.EntraExists -eq $false }).Count
        $entraErrors = ($results | Where-Object { $_.EntraExists -eq $null }).Count
        
        Write-ColorOutput "Entra ID - Found: $entraFound, Not Found: $entraNotFound, Errors: $entraErrors" "White"
        
        # Objects missing from either environment
        $missingFromOnPrem = ($results | Where-Object { $_.OnPremExists -eq $false }).Count
        $missingFromEntra = ($results | Where-Object { $_.EntraExists -eq $false }).Count
        $missingFromBoth = ($results | Where-Object { $_.OnPremExists -eq $false -and $_.EntraExists -eq $false }).Count
        
        Write-ColorOutput "Missing from On-premises AD: $missingFromOnPrem" "Yellow"
        Write-ColorOutput "Missing from Entra ID: $missingFromEntra" "Yellow"
        Write-ColorOutput "Missing from both: $missingFromBoth" "Red"
    }
    
    # Export results to CSV
    Write-ColorOutput "`nExporting results to: $OutputPath" "Green"
    $results | Export-Csv -Path $OutputPath -NoTypeInformation -ErrorAction Stop
    Write-ColorOutput "Results exported successfully" "Green"
    
    # Display objects not found in either environment
    Write-ColorOutput "`n=== OBJECTS NOT FOUND ===" "Cyan"
    
    $notFoundObjects = $results | Where-Object { $_.OnPremExists -eq $false -or $_.EntraExists -eq $false }
    
    if ($notFoundObjects.Count -gt 0) {
        foreach ($obj in $notFoundObjects) {
            $status = @()
            if ($obj.OnPremExists -eq $false) { $status += "OnPrem" }
            if ($obj.EntraExists -eq $false) { $status += "Entra" }
            
            Write-ColorOutput "$($obj.Name) - Missing from: $($status -join ', ')" "Red"
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