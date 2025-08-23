# Copyright (c) Microsoft Corporation.
# Licensed under the MIT License.

<#
.SYNOPSIS
    Gets all members of a group recursively, including nested groups.

.DESCRIPTION
    This script uses Microsoft Graph PowerShell to retrieve all members of a specified group.
    If the group contains nested groups, it will recursively get all members of those groups as well.
    The script handles both users and groups, and provides detailed output including user properties.
    Duplicate members are automatically detected and removed to ensure unique results.

.PARAMETER GroupName
    The display name of the group to get members for.

.PARAMETER GroupId
    The Object ID of the group to get members for. If not specified, GroupName will be used to find the group.

.PARAMETER ExportToCsv
    Switch parameter to export results to a CSV file.

.PARAMETER CsvPath
    The path where the CSV file should be saved. Defaults to current directory with timestamp.

.PARAMETER IncludeGroupInfo
    Switch parameter to include information about nested groups in the output.

.EXAMPLE
    .\Get-RecursiveGroupMember.ps1 -GroupName "IT Department"

.EXAMPLE
    .\Get-RecursiveGroupMember.ps1 -GroupId "12345678-1234-1234-1234-123456789012" -ExportToCsv

.EXAMPLE
    .\Get-RecursiveGroupMember.ps1 -GroupName "Security Groups" -IncludeGroupInfo -ExportToCsv -CsvPath "C:\Temp\GroupMembers.csv"

.NOTES
    Requires Microsoft Graph PowerShell module and appropriate permissions.
    Scopes required: Directory.Read.All, Group.Read.All
#>

[CmdletBinding(DefaultParameterSetName = 'ByName')]
param(
    [Parameter(ParameterSetName = 'ByName', Mandatory = $true, Position = 0)]
    [string]$GroupName,

    [Parameter(ParameterSetName = 'ById', Mandatory = $true)]
    [string]$GroupId,

    [Parameter()]
    [string]$CsvPath,

    [Parameter()]
    [switch]$IncludeGroupInfo,

    [Parameter()]
    [switch]$RemoveDuplicateMembers,

    [Parameter()]
    [switch]$SaveLog
)

# Initialize variables
$script:processedGroups = @{}
$script:processedMembers = @{}  # Track unique members by ID to prevent duplicates
$script:allMembers = @()
$script:groupStack = @()

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = "Info"
    )

    $timestamp = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
    $logMessage = "[$timestamp] [$Level] $Message"

    # Save log to file if requested
    if ($SaveLog) {
        if (-not $script:LogFilePath) {
            $logDir = Join-Path $PSScriptRoot 'log'
            if (-not (Test-Path $logDir)) { New-Item -Path $logDir -ItemType Directory | Out-Null }
            $logFileName = "$(Get-Date -Format 'yyyy-MM-dd HH-mm-ss').log"
            $script:LogFilePath = Join-Path $logDir $logFileName
        }
        Add-Content -Path $script:LogFilePath -Value $logMessage
    }

    switch ($Level) {
        "Error"    { Write-Host $logMessage -ForegroundColor Red }
        "Warning"  { Write-Host $logMessage -ForegroundColor Yellow }
        "Success"  { Write-Host $logMessage -ForegroundColor Green }
        "Info"     { Write-Host $logMessage -ForegroundColor Green }
        default    { Write-Host $logMessage -ForegroundColor Green }
    }
}

function Test-GraphConnection {
    try {
        $context = Get-MgContext -ErrorAction Stop
        if ($null -eq $context) {
            Write-Log "Not connected to Microsoft Graph. Attempting to connect..." "Warning"
            Connect-MgGraph -Scopes "Directory.Read.All", "Group.Read.All" -ErrorAction Stop
            Write-Log "Successfully connected to Microsoft Graph" "Success"
        } else {
            Write-Log "Already connected to Microsoft Graph" "Info"
        }
    }
    catch {
        Write-Log "Failed to connect to Microsoft Graph: $($_.Exception.Message)" "Error"
        throw
    }
}

function Get-GroupById {
    param([string]$GroupId)
    
    try {
        $group = Get-MgGroup -GroupId $GroupId -ErrorAction Stop
        return $group
    }
    catch {
        Write-Log "Failed to get group with ID '$GroupId': $($_.Exception.Message)" "Error"
        return $null
    }
}

function Get-GroupByName {
    param([string]$GroupName)
    
    try {
        $groups = Get-MgGroup -Filter "DisplayName eq '$GroupName'" -ErrorAction Stop
        
        if ($groups.Count -eq 0) {
            Write-Log "No group found with name '$GroupName'" "Error"
            return $null
        }
        elseif ($groups.Count -gt 1) {
            Write-Log "Multiple groups found with name '$GroupName'. Using the first one." "Warning"
            return $groups[0]
        }
        
        return $groups
    }
    catch {
        Write-Log "Failed to get group with name '$GroupName': $($_.Exception.Message)" "Error"
        return $null
    }
}

function Get-RecursiveGroupMembers {
    param(
        [string]$GroupId,
        [string]$GroupName,
        [string]$ParentGroupName = ""
    )
    
    # Check for circular references
    if ($script:processedGroups.ContainsKey($GroupId)) {
        Write-Log "Circular reference detected for group '$GroupName' ($GroupId). Skipping to prevent infinite loop." "Warning"
        return
    }
    
    # Mark this group as processed
    $script:processedGroups[$GroupId] = $true
    
    # Add to group stack for tracking hierarchy
    $script:groupStack += $GroupName
    
    Write-Log "Processing group: $GroupName (ID: $GroupId)" "Info"
    
    try {
        # Get all members of the group
        $members = Get-MgGroupMember -GroupId $GroupId -All -ErrorAction Stop
        
        if ($members.Count -eq 0) {
            Write-Log "No members found in group '$GroupName'" "Info"
        } else {
            Write-Log "Found $($members.Count) members in group '$GroupName'" "Info"
        }
        
        foreach ($member in $members) {
            $memberType = $member.AdditionalProperties.'@odata.type'
            
            if ($memberType -eq "#microsoft.graph.user") {
                # Process user member
                try {
                    $user = Get-MgUser -UserId $member.Id -Property DisplayName, UserPrincipalName, Mail, JobTitle, Department, OfficeLocation -ErrorAction Stop
                    
                    $memberObject = [PSCustomObject]@{
                        MemberType = "User"
                        DisplayName = $user.DisplayName
                        UserPrincipalName = $user.UserPrincipalName
                        Email = $user.Mail
                        JobTitle = $user.JobTitle
                        Department = $user.Department
                        OfficeLocation = $user.OfficeLocation
                        MemberId = $member.Id
                        DirectGroup = $GroupName
                        ParentGroup = $ParentGroupName
                        GroupHierarchy = ($script:groupStack -join " > ")
                        ProcessingDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                    }
                    
                    # Check for duplicates
                    if ($RemoveDuplicateMembers) {
                        if (-not $script:processedMembers.ContainsKey($member.Id)) {
                            $script:allMembers += $memberObject
                            $script:processedMembers[$member.Id] = $true
                            Write-Log "Added user: $($user.DisplayName) ($($user.UserPrincipalName))" "Info"
                        } else {
                            Write-Log "Skipped duplicate user: $($user.DisplayName) ($($user.UserPrincipalName))" "Warning"
                        }
                    } else {
                        $script:allMembers += $memberObject
                        Write-Log "Added user: $($user.DisplayName) ($($user.UserPrincipalName))" "Info"
                    }
                }
                catch {
                    Write-Log "Failed to get user details for ID '$($member.Id)': $($_.Exception.Message)" "Error"
                }
            }
            elseif ($memberType -eq "#microsoft.graph.group") {
                # Process nested group
                try {
                    $nestedGroup = Get-MgGroup -GroupId $member.Id -Property DisplayName -ErrorAction Stop
                    
                    if ($IncludeGroupInfo) {
                        $groupObject = [PSCustomObject]@{
                            MemberType = "Group"
                            DisplayName = $nestedGroup.DisplayName
                            UserPrincipalName = ""
                            Email = ""
                            JobTitle = ""
                            Department = ""
                            OfficeLocation = ""
                            MemberId = $member.Id
                            DirectGroup = $GroupName
                            ParentGroup = $ParentGroupName
                            GroupHierarchy = ($script:groupStack -join " > ")
                            ProcessingDate = Get-Date -Format "yyyy-MM-dd HH:mm:ss"
                        }
                        
                        # Check for duplicates
                        if ($RemoveDuplicateMembers) {
                            if (-not $script:processedMembers.ContainsKey($member.Id)) {
                                $script:allMembers += $groupObject
                                $script:processedMembers[$member.Id] = $true
                                Write-Log "Added nested group: $($nestedGroup.DisplayName)" "Info"
                            } else {
                                Write-Log "Skipped duplicate nested group: $($nestedGroup.DisplayName)" "Info"
                            }
                        } else {
                            $script:allMembers += $groupObject
                            Write-Log "Added nested group: $($nestedGroup.DisplayName)" "Info"
                        }
                    }
                    
                    # Recursively get members of the nested group
                    $newParentGroup = if ($ParentGroupName) { "$ParentGroupName > $GroupName" } else { $GroupName }
                    Get-RecursiveGroupMembers -GroupId $member.Id -GroupName $nestedGroup.DisplayName -ParentGroupName $newParentGroup
                }
                catch {
                    Write-Log "Failed to get nested group details for ID '$($member.Id)': $($_.Exception.Message)" "Error"
                }
            }
            else {
                Write-Log "Unknown member type: $memberType for member ID: $($member.Id)" "Warning"
            }
        }
    }
    catch {
        Write-Log "Failed to get members for group '$GroupName': $($_.Exception.Message)" "Error"
    }
    
    # Remove from group stack
    $script:groupStack = $script:groupStack[0..($script:groupStack.Count-2)]
}

# Main execution
try {
    Write-Log "Starting recursive group member retrieval" "Info"
    
    # Test Graph connection
    Test-GraphConnection
    
    # Get the target group
    $targetGroup = $null
    if ($PSCmdlet.ParameterSetName -eq 'ById') {
        $targetGroup = Get-GroupById -GroupId $GroupId
    } else {
        $targetGroup = Get-GroupByName -GroupName $GroupName
    }
    
    if ($null -eq $targetGroup) {
        Write-Log "Could not find the specified group. Exiting." "Error"
        exit 1
    }
    
    Write-Log "Found target group: $($targetGroup.DisplayName) (ID: $($targetGroup.Id))" "Success"
    
    # Start recursive processing
    Get-RecursiveGroupMembers -GroupId $targetGroup.Id -GroupName $targetGroup.DisplayName
    
    # Display results
    Write-Log "Processing complete. Found $($script:allMembers.Count) unique members." "Success"
    
    if ($script:allMembers.Count -gt 0) {
        # Display summary
        $userCount = ($script:allMembers | Where-Object { $_.MemberType -eq "User" }).Count
        $groupCount = ($script:allMembers | Where-Object { $_.MemberType -eq "Group" }).Count
        
        Write-Log "Summary: $userCount unique users, $groupCount unique groups" "Info"
        
        # Show results
        $script:allMembers | Format-Table -AutoSize
        
        # Export to CSV if path is provided
        if ($CsvPath) {
            try {
                $script:allMembers | Export-Csv -Path $CsvPath -NoTypeInformation -Encoding UTF8
                Write-Log "Results exported to: $CsvPath" "Success"
            }
            catch {
                Write-Log "Failed to export to CSV: $($_.Exception.Message)" "Error"
            }
        }
    } else {
        Write-Log "No members found in the specified group or its nested groups." "Info"
    }
}
catch {
    Write-Log "Script execution failed: $($_.Exception.Message)" "Error"
    exit 1
}
finally {
    # Clean up
    if ($null -ne (Get-MgContext)) {
        Disconnect-MgGraph -ErrorAction SilentlyContinue
        Write-Log "Disconnected from Microsoft Graph" "Info"
    }
}
