<#
.SYNOPSIS
    Bulk mail-enable distribution groups from a CSV file on on-prem Exchange.

.PARAMETER CsvFile
    Path to the CSV file with columns: Name, PrimarySMTPAddress.

.PARAMETER HiddenFromGAL
    Optional. If $true, hides the group from the Global Address List (GAL). Default is $false.

.NOTES
    Must be run on an on-prem Exchange server with the Exchange Management Shell.
#>

[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)]
    [string]$CsvFile,

    [Parameter()]
    [bool]$HiddenFromGAL = $false
)

function Write-Log {
    param(
        [string]$Message,
        [string]$Level = 'INFO'
    )
    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    Write-Host "[$timestamp][$Level] $Message"
}

# Check if running on on-prem Exchange
try {
    $exch = Get-Command Enable-DistributionGroup -ErrorAction Stop
    if ($exch.Source -notlike "*Microsoft.Exchange.Management*") {
        throw
    }
} catch {
    Write-Error "This script must be run on an on-prem Exchange server with the Exchange Management Shell."
    exit 1
}

# Validate CSV file
if (-not (Test-Path -Path $CsvFile)) {
    Write-Error "CSV file not found: $CsvFile"
    exit 1
}

try {
    $csv = Import-Csv -Path $CsvFile -ErrorAction Stop
} catch {
    Write-Error "Failed to import CSV: $_"
    exit 1
}

if ($csv.Count -eq 0) {
    Write-Error "CSV contains no rows."
    exit 1
}

$requiredHeaders = @('Name', 'PrimarySMTPAddress')
foreach ($header in $requiredHeaders) {
    if (-not ($csv | Get-Member -Name $header -MemberType NoteProperty -ErrorAction SilentlyContinue)) {
        Write-Error "CSV must contain a column named '$header'."
        exit 1
    }
}

# Prepare list of groups to enable
$toEnable = @()
foreach ($row in $csv) {
    if ([string]::IsNullOrWhiteSpace($row.Name) -or [string]::IsNullOrWhiteSpace($row.PrimarySMTPAddress)) {
        Write-Log "Skipping row with missing Name or PrimarySMTPAddress" "WARN"
        continue
    }
    $toEnable += $row
}

if ($toEnable.Count -eq 0) {
    Write-Error "No valid distribution groups found in CSV."
    exit 1
}

Write-Host "`nThe following distribution groups will be mail-enabled:" -ForegroundColor Cyan
$toEnable | ForEach-Object { Write-Host "- $($_.Name) <$($_.PrimarySMTPAddress)>" }

$confirm = Read-Host "Proceed with mail-enabling these groups? (Y/N)"
if ($confirm.ToUpper() -ne 'Y') {
    Write-Log "User aborted operation."
    exit 0
}

# Prepare log files
$logFolder = Split-Path -Parent (Resolve-Path $CsvFile)
$successLog = Join-Path $logFolder ("Enable-BulkDistributionGroups_Success_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
$failLog = Join-Path $logFolder ("Enable-BulkDistributionGroups_Fail_{0:yyyyMMdd_HHmmss}.csv" -f (Get-Date))
$successList = @()
$failList = @()

foreach ($group in $toEnable) {
    try {
        $params = @{
            Identity = $group.Name
            PrimarySmtpAddress = $group.PrimarySMTPAddress
        }
        Enable-DistributionGroup @params -ErrorAction Stop
        if ($HiddenFromGAL) {
            Set-DistributionGroup -Identity $group.Name -HiddenFromAddressListsEnabled $true -ErrorAction Stop
        }
        Write-Log "SUCCESS: Enabled $($group.Name) <$($group.PrimarySMTPAddress)>"
        $successList += [PSCustomObject]@{
            Name = $group.Name
            PrimarySMTPAddress = $group.PrimarySMTPAddress
            HiddenFromGAL = $HiddenFromGAL
            Status = "Success"
        }
    } catch {
        Write-Log "FAILED: $($group.Name) <$($group.PrimarySMTPAddress)> - $_" "ERROR"
        $failList += [PSCustomObject]@{
            Name = $group.Name
            PrimarySMTPAddress = $group.PrimarySMTPAddress
            HiddenFromGAL = $HiddenFromGAL
            Status = "Failed"
            Error = $_.Exception.Message
        }
    }
}

if ($successList.Count -gt 0) {
    $successList | Export-Csv -Path $successLog -NoTypeInformation
    Write-Log "Success log written to $successLog"
}
if ($failList.Count -gt 0) {
    $failList | Export-Csv -Path $failLog -NoTypeInformation
    Write-Log "Failure log written to $failLog"
}

Write-Log "Script completed."