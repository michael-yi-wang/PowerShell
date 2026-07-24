# Update-DNSNameServer Add-side IP Verification Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Make `-AddNameServer` runs of `Update-DNSNameServer.ps1` require an IP address and report, per candidate zone, whether the target DC's A record now exists and matches that IP - without ever writing an A record.

**Architecture:** Single-file PowerShell script change. `-NameServerIPAddress` becomes mandatory on the `Add` parameter set. The per-zone analysis loop (Step 5) always computes a structured `IPVerificationStatus` (`Matched`/`Mismatch`/`NotFound`) alongside the existing NS-presence check. The post-analysis flow (Steps 6-8) splits into two independent branches: the `Remove` branch is untouched from today's behavior; the `Add` branch drops its "nothing to do" early-exit, always builds a result row for every candidate zone (not just changed ones), prints an IP-verification summary, and exports a CSV with two new columns.

**Tech Stack:** PowerShell (5.1 + 7 compatible), `DnsServer` module (Windows-only).

**Reference spec:** `docs/superpowers/specs/2026-07-23-update-dnsnameserver-ip-verification-design.md`

---

### Task 1: Make `-NameServerIPAddress` mandatory and update comment-based help

**Files:**
- Modify: `Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1`
- Test: none (comment/parameter-only change; validated via AST parse in Step 4 below)

- [ ] **Step 1: Update the `.DESCRIPTION` block to mention IP verification**

In `/Users/michael/Documents/Git/PowerShell/Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1`, find:

```powershell
.DESCRIPTION
    When a new domain controller is promoted, it should be added as a name
    server on every forward lookup zone. When an old domain controller is
    demoted, its name server delegation should be removed from those same
    zones. This script performs either action across all forward lookup
    zones on a DNS server (or a specified subset), after checking whether the
    name server is already present/absent so it only changes zones that
    actually need it.

    The script must be run on a domain controller. It uses the DnsServer
    PowerShell module, which is only available on Windows with the DNS
    Server tools (RSAT-DNS-Server) installed.

    All actions and errors are logged to a timestamped .log file, and results
    are exported to a timestamped .csv file, both saved next to the script.
```

Replace with:

```powershell
.DESCRIPTION
    When a new domain controller is promoted, it should be added as a name
    server on every forward lookup zone. When an old domain controller is
    demoted, its name server delegation should be removed from those same
    zones. This script performs either action across all forward lookup
    zones on a DNS server (or a specified subset), after checking whether the
    name server is already present/absent so it only changes zones that
    actually need it.

    On -AddNameServer runs, every candidate zone is also checked (read-only)
    for whether the new DC's A (host) record has appeared and matches the
    supplied -NameServerIPAddress. This runs even for zones where the NS
    record was already present, so you can confirm a DC's DNS registration
    has caught up after promotion without re-running the whole script.

    The script must be run on a domain controller. It uses the DnsServer
    PowerShell module, which is only available on Windows with the DNS
    Server tools (RSAT-DNS-Server) installed.

    All actions and errors are logged to a timestamped .log file, and results
    are exported to a timestamped .csv file, both saved next to the script.
```

- [ ] **Step 2: Update the `.PARAMETER NameServerIPAddress` help text**

Find:

```powershell
.PARAMETER NameServerIPAddress
    Optional. Only used with -AddNameServer. The IPv4/IPv6 address of the new
    domain controller. Used purely to verify and log whether a matching A
    (host) record already exists in each zone - the script never creates or
    modifies A records, since domain controllers self-register those via
    dynamic DNS update.
```

Replace with:

```powershell
.PARAMETER NameServerIPAddress
    Required with -AddNameServer. The IPv4 address of the new domain
    controller. Used to check every candidate zone for a matching A (host)
    record and report a per-zone IPVerificationStatus of Matched, Mismatch,
    or NotFound - the script never creates or modifies A records itself,
    since domain controllers self-register those via dynamic DNS update.
```

- [ ] **Step 3: Make the parameter itself mandatory**

Find:

```powershell
    [Parameter(ParameterSetName = 'Add')]
    [ValidateNotNullOrEmpty()]
    [string]$NameServerIPAddress,
```

Replace with:

```powershell
    [Parameter(Mandatory = $true, ParameterSetName = 'Add')]
    [ValidateNotNullOrEmpty()]
    [string]$NameServerIPAddress,
```

- [ ] **Step 4: Bump the version in `.NOTES`**

Find:

```powershell
.NOTES
    Author  : Michael Wang
    Version : 1.1
    Date    : 2026-07-23
```

Replace with:

```powershell
.NOTES
    Author  : Michael Wang
    Version : 1.2
    Date    : 2026-07-23
```

- [ ] **Step 5: Validate the file still parses**

Run:

```bash
pwsh -NoProfile -Command "\$errors = \$null; [System.Management.Automation.Language.Parser]::ParseFile('/Users/michael/Documents/Git/PowerShell/Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1', [ref]\$null, [ref]\$errors) | Out-Null; if (\$errors) { \$errors } else { 'No syntax errors' }"
```

Expected: `No syntax errors`

- [ ] **Step 6: Commit**

```bash
cd "/Users/michael/Documents/Git/PowerShell"
git add "Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1"
git commit -m "$(cat <<'EOF'
Make -NameServerIPAddress mandatory for Update-DNSNameServer Add runs

Verification of the DC's A record needs a known-good IP to compare
against, so an IP-less Add run no longer makes sense.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 2: Replace free-text A-record note with structured IP verification status

**Files:**
- Modify: `Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1`
- Test: none (validated via AST parse; this task only changes the analysis loop, `$WorkItems` is not consumed downstream yet - that's Task 3)

- [ ] **Step 1: Replace the Step 5 analysis loop**

Find this entire block (the "Step 5: Check existing state per zone" section, including the trailing `$Skipped` loop):

```powershell
# ----------------------------------------------------------------------------
# Step 5: Check existing state per zone
# ----------------------------------------------------------------------------
$WorkItems = @()

foreach ($Zone in $ForwardZones) {
    $ZoneNameValue = $Zone.ZoneName
    $ExistingNsHosts = @()

    try {
        $NsRecords = Get-DnsServerResourceRecord -ZoneName $ZoneNameValue -RRType Ns -Node -ComputerName $DnsServer -ErrorAction Stop
        $ExistingNsHosts = $NsRecords | ForEach-Object { $_.RecordData.NameServer.TrimEnd('.') }
    } catch {
        Write-Log -Level Warning -Message "Could not read NS records for zone '$ZoneNameValue': $_"
    }

    $AlreadyPresent = $ExistingNsHosts -contains $NormalizedHostName

    $NeedsChange = if ($AddNameServer) { -not $AlreadyPresent } else { $AlreadyPresent }

    $ARecordNote = $null
    if ($AddNameServer -and $NameServerIPAddress) {
        try {
            $ARecord = Get-DnsServerResourceRecord -ZoneName $ZoneNameValue -Name $HostShortName -RRType A -ComputerName $DnsServer -ErrorAction Stop
            $ExistingIP = $ARecord | Select-Object -First 1 -ExpandProperty RecordData | Select-Object -ExpandProperty IPv4Address -ErrorAction SilentlyContinue
            if ($ExistingIP -and $ExistingIP.ToString() -eq $NameServerIPAddress) {
                $ARecordNote = "A record already present and matches $NameServerIPAddress"
            } elseif ($ExistingIP) {
                $ARecordNote = "A record present but IP ($ExistingIP) differs from provided $NameServerIPAddress"
            } else {
                $ARecordNote = 'A record present but no IPv4 address found'
            }
        } catch {
            $ARecordNote = "No A record found for '$HostShortName' in this zone (not created by this script)"
        }
        Write-Log -Level Info -Message "Zone '$ZoneNameValue': $ARecordNote"
    }

    $WorkItems += [PSCustomObject]@{
        ZoneName       = $ZoneNameValue
        Action         = $Action
        AlreadyPresent = $AlreadyPresent
        NeedsChange    = $NeedsChange
        ARecordNote    = $ARecordNote
    }
}

$ToChange = $WorkItems | Where-Object { $_.NeedsChange }
$Skipped  = $WorkItems | Where-Object { -not $_.NeedsChange }

foreach ($Item in $Skipped) {
    $Reason = if ($AddNameServer) { 'already a name server on this zone' } else { 'not currently a name server on this zone' }
    Write-Log -Level Info -Message "Skipping zone '$($Item.ZoneName)': $NormalizedHostName is $Reason."
}
```

Replace with:

```powershell
# ----------------------------------------------------------------------------
# Step 5: Check existing state per zone
# ----------------------------------------------------------------------------
$WorkItems = @()

foreach ($Zone in $ForwardZones) {
    $ZoneNameValue = $Zone.ZoneName
    $ExistingNsHosts = @()

    try {
        $NsRecords = Get-DnsServerResourceRecord -ZoneName $ZoneNameValue -RRType Ns -Node -ComputerName $DnsServer -ErrorAction Stop
        $ExistingNsHosts = $NsRecords | ForEach-Object { $_.RecordData.NameServer.TrimEnd('.') }
    } catch {
        Write-Log -Level Warning -Message "Could not read NS records for zone '$ZoneNameValue': $_"
    }

    $AlreadyPresent = $ExistingNsHosts -contains $NormalizedHostName

    $NeedsChange = if ($AddNameServer) { -not $AlreadyPresent } else { $AlreadyPresent }

    $IPVerificationStatus = $null
    $IPVerificationDetail = $null
    if ($AddNameServer) {
        try {
            $ARecord = Get-DnsServerResourceRecord -ZoneName $ZoneNameValue -Name $HostShortName -RRType A -ComputerName $DnsServer -ErrorAction Stop
            $ExistingIP = $ARecord | Select-Object -First 1 -ExpandProperty RecordData | Select-Object -ExpandProperty IPv4Address -ErrorAction SilentlyContinue
            if ($ExistingIP -and $ExistingIP.ToString() -eq $NameServerIPAddress) {
                $IPVerificationStatus = 'Matched'
                $IPVerificationDetail = "A record matches $NameServerIPAddress"
            } elseif ($ExistingIP) {
                $IPVerificationStatus = 'Mismatch'
                $IPVerificationDetail = "A record found with IP $ExistingIP, expected $NameServerIPAddress"
            } else {
                $IPVerificationStatus = 'NotFound'
                $IPVerificationDetail = 'A record present but no IPv4 address found'
            }
        } catch {
            $IPVerificationStatus = 'NotFound'
            $IPVerificationDetail = "No A record found for '$HostShortName' in this zone (not created by this script)"
        }

        $VerificationLogLevel = if ($IPVerificationStatus -eq 'Matched') { 'Info' } else { 'Warning' }
        Write-Log -Level $VerificationLogLevel -Message "Zone '$ZoneNameValue': IP verification - $IPVerificationStatus. $IPVerificationDetail"
    }

    $WorkItems += [PSCustomObject]@{
        ZoneName              = $ZoneNameValue
        Action                = $Action
        AlreadyPresent        = $AlreadyPresent
        NeedsChange           = $NeedsChange
        IPVerificationStatus  = $IPVerificationStatus
        IPVerificationDetail  = $IPVerificationDetail
    }
}

$ToChange = $WorkItems | Where-Object { $_.NeedsChange }
$Skipped  = $WorkItems | Where-Object { -not $_.NeedsChange }

foreach ($Item in $Skipped) {
    $Reason = if ($AddNameServer) { 'already a name server on this zone' } else { 'not currently a name server on this zone' }
    Write-Log -Level Info -Message "Skipping NS change for zone '$($Item.ZoneName)': $NormalizedHostName is $Reason."
}
```

Note: `IPVerificationStatus`/`IPVerificationDetail` replace `ARecordNote` (which no downstream code referenced, so this is a safe rename). The `if ($AddNameServer -and $NameServerIPAddress)` guard collapses to `if ($AddNameServer)` because Task 1 made `-NameServerIPAddress` mandatory whenever `-AddNameServer` is used.

- [ ] **Step 2: Validate the file still parses**

Run:

```bash
pwsh -NoProfile -Command "\$errors = \$null; [System.Management.Automation.Language.Parser]::ParseFile('/Users/michael/Documents/Git/PowerShell/Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1', [ref]\$null, [ref]\$errors) | Out-Null; if (\$errors) { \$errors } else { 'No syntax errors' }"
```

Expected: `No syntax errors`

- [ ] **Step 3: Commit**

```bash
cd "/Users/michael/Documents/Git/PowerShell"
git add "Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1"
git commit -m "$(cat <<'EOF'
Compute structured IP verification status per zone

Replaces the free-text A-record note with a Matched/Mismatch/NotFound
status plus a detail string, computed for every candidate zone on Add
runs (not just ones needing an NS change), and logged at Info/Warning
accordingly.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 3: Split summary/execution/export into Remove (unchanged) and Add (verification-aware) branches

**Files:**
- Modify: `Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1`
- Test: none (validated via AST parse + manual trace-through in Task 5)

- [ ] **Step 1: Replace Steps 6-8 with the branched flow**

Find this entire block (from the "Step 6: Summary and confirmation" comment through the end of the file):

```powershell
# ----------------------------------------------------------------------------
# Step 6: Summary and confirmation
# ----------------------------------------------------------------------------
if (@($ToChange).Count -eq 0) {
    Write-Host "`nNo zones require a change. Nothing to do." -ForegroundColor Green
    Write-Log -Level Info -Message 'No zones required a change. Exiting.'
    return
}

Write-Host "`n$Action name server '$NormalizedHostName' on the following zone(s):`n" -ForegroundColor Cyan
$ToChange | ForEach-Object { Write-Host "- $($_.ZoneName)" }
Write-Host "`nLog file: $LogFile`n"

if (-not $Force) {
    $Confirm = Read-Host "Proceed with $Action on the $(@($ToChange).Count) listed zone(s)? (Y/N)"
    if ($Confirm.ToUpper() -ne 'Y') {
        Write-Log -Level Info -Message 'User aborted before making any changes.'
        return
    }
}

# ----------------------------------------------------------------------------
# Step 7: Execute
# ----------------------------------------------------------------------------
$Results = @()

foreach ($Item in $ToChange) {
    $ZoneNameValue = $Item.ZoneName
    $Result = 'Success'
    $Message = ''

    try {
        if ($AddNameServer) {
            Add-DnsServerResourceRecord -ZoneName $ZoneNameValue -Name '@' -Ns -NameServer $RecordDataHostName -ComputerName $DnsServer -WhatIf:$WhatIf -ErrorAction Stop
            $Message = "Added NS record for $NormalizedHostName"
        } else {
            Remove-DnsServerResourceRecord -ZoneName $ZoneNameValue -RRType Ns -Name '@' -RecordData $RecordDataHostName -ComputerName $DnsServer -Force -WhatIf:$WhatIf -ErrorAction Stop
            $Message = "Removed NS record for $NormalizedHostName"
        }
        Write-Log -Level Info -Message "Zone '$ZoneNameValue': $Message"
    } catch {
        $Result = 'Failed'
        $Message = "$_"
        Write-Log -Level Error -Message "Zone '$ZoneNameValue': failed to $Action name server - $Message"
    }

    $Results += [PSCustomObject]@{
        ZoneName       = $ZoneNameValue
        Action         = $Action
        PreviousState  = if ($Item.AlreadyPresent) { 'Present' } else { 'Absent' }
        Result         = $Result
        Message        = $Message
        Timestamp      = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
}

# ----------------------------------------------------------------------------
# Step 8: Export results and finish
# ----------------------------------------------------------------------------
$Results | Export-Csv -Path $CsvOutput -NoTypeInformation -Encoding utf8
Write-Log -Level Info -Message "Results exported to $CsvOutput"

$FailedCount = @($Results | Where-Object { $_.Result -eq 'Failed' }).Count
if ($FailedCount -gt 0) {
    Write-Log -Level Warning -Message "$FailedCount zone(s) failed to update. Review the log and CSV for details."
}

Write-Log -Level Info -Message 'Script finished.'
```

Replace with:

```powershell
# ----------------------------------------------------------------------------
# Step 6: Remove flow - summary, confirmation, execution, export (unchanged
# behavior - Add-side IP verification does not apply to Remove)
# ----------------------------------------------------------------------------
if ($RemoveNameServer) {
    if (@($ToChange).Count -eq 0) {
        Write-Host "`nNo zones require a change. Nothing to do." -ForegroundColor Green
        Write-Log -Level Info -Message 'No zones required a change. Exiting.'
        return
    }

    Write-Host "`n$Action name server '$NormalizedHostName' on the following zone(s):`n" -ForegroundColor Cyan
    $ToChange | ForEach-Object { Write-Host "- $($_.ZoneName)" }
    Write-Host "`nLog file: $LogFile`n"

    if (-not $Force) {
        $Confirm = Read-Host "Proceed with $Action on the $(@($ToChange).Count) listed zone(s)? (Y/N)"
        if ($Confirm.ToUpper() -ne 'Y') {
            Write-Log -Level Info -Message 'User aborted before making any changes.'
            return
        }
    }

    $Results = @()

    foreach ($Item in $ToChange) {
        $ZoneNameValue = $Item.ZoneName
        $Result = 'Success'
        $Message = ''

        try {
            Remove-DnsServerResourceRecord -ZoneName $ZoneNameValue -RRType Ns -Name '@' -RecordData $RecordDataHostName -ComputerName $DnsServer -Force -WhatIf:$WhatIf -ErrorAction Stop
            $Message = "Removed NS record for $NormalizedHostName"
            Write-Log -Level Info -Message "Zone '$ZoneNameValue': $Message"
        } catch {
            $Result = 'Failed'
            $Message = "$_"
            Write-Log -Level Error -Message "Zone '$ZoneNameValue': failed to $Action name server - $Message"
        }

        $Results += [PSCustomObject]@{
            ZoneName      = $ZoneNameValue
            Action        = $Action
            PreviousState = if ($Item.AlreadyPresent) { 'Present' } else { 'Absent' }
            Result        = $Result
            Message       = $Message
            Timestamp     = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
        }
    }

    $Results | Export-Csv -Path $CsvOutput -NoTypeInformation -Encoding utf8
    Write-Log -Level Info -Message "Results exported to $CsvOutput"

    $FailedCount = @($Results | Where-Object { $_.Result -eq 'Failed' }).Count
    if ($FailedCount -gt 0) {
        Write-Log -Level Warning -Message "$FailedCount zone(s) failed to update. Review the log and CSV for details."
    }

    Write-Log -Level Info -Message 'Script finished.'
    return
}

# ----------------------------------------------------------------------------
# Step 7: Add flow - summary and confirmation
# ----------------------------------------------------------------------------
$HasChanges = @($ToChange).Count -gt 0

if ($HasChanges) {
    Write-Host "`n$Action name server '$NormalizedHostName' on the following zone(s):`n" -ForegroundColor Cyan
    $ToChange | ForEach-Object { Write-Host "- $($_.ZoneName)" }
    Write-Host "`nLog file: $LogFile`n"

    if (-not $Force) {
        $Confirm = Read-Host "Proceed with $Action on the $(@($ToChange).Count) listed zone(s)? (Y/N)"
        if ($Confirm.ToUpper() -ne 'Y') {
            Write-Log -Level Info -Message 'User aborted before making any changes.'
            return
        }
    }
} else {
    Write-Host "`nNo zones require the NS record to be added. Continuing with IP verification only.`n" -ForegroundColor Green
    Write-Log -Level Info -Message 'No zones required an NS record change. Continuing with IP verification reporting.'
}

# ----------------------------------------------------------------------------
# Step 8: Add flow - execute NS changes and build a result row per candidate
# zone (not just changed ones, so already-present zones still get their IP
# verification status reported)
# ----------------------------------------------------------------------------
$Results = @()

foreach ($Item in $WorkItems) {
    $ZoneNameValue = $Item.ZoneName

    if ($Item.NeedsChange) {
        $Result  = 'Success'
        $Message = ''
        try {
            Add-DnsServerResourceRecord -ZoneName $ZoneNameValue -Name '@' -Ns -NameServer $RecordDataHostName -ComputerName $DnsServer -WhatIf:$WhatIf -ErrorAction Stop
            $Message = "Added NS record for $NormalizedHostName"
            Write-Log -Level Info -Message "Zone '$ZoneNameValue': $Message"
        } catch {
            $Result  = 'Failed'
            $Message = "$_"
            Write-Log -Level Error -Message "Zone '$ZoneNameValue': failed to $Action name server - $Message"
        }
    } else {
        $Result  = 'Skipped'
        $Message = "$NormalizedHostName already a name server on this zone"
    }

    $Results += [PSCustomObject]@{
        ZoneName             = $ZoneNameValue
        Action               = $Action
        PreviousState        = if ($Item.AlreadyPresent) { 'Present' } else { 'Absent' }
        Result               = $Result
        Message              = $Message
        IPVerificationStatus = $Item.IPVerificationStatus
        IPVerificationDetail = $Item.IPVerificationDetail
        Timestamp            = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    }
}

# ----------------------------------------------------------------------------
# Step 9: Add flow - IP verification summary
# ----------------------------------------------------------------------------
$NeedsAttention = $Results | Where-Object { $_.IPVerificationStatus -in 'Mismatch', 'NotFound' }
$VerifiedCount  = @($Results | Where-Object { $_.IPVerificationStatus -eq 'Matched' }).Count

Write-Host "`nIP verification: $VerifiedCount of $(@($Results).Count) zone(s) verified.`n" -ForegroundColor Cyan
if (@($NeedsAttention).Count -gt 0) {
    Write-Host "The following zone(s) need attention:`n" -ForegroundColor Yellow
    $NeedsAttention | ForEach-Object { Write-Host "- $($_.ZoneName): $($_.IPVerificationStatus) - $($_.IPVerificationDetail)" -ForegroundColor Yellow }
    Write-Host ''
}

# ----------------------------------------------------------------------------
# Step 10: Add flow - export results and finish
# ----------------------------------------------------------------------------
$Results | Export-Csv -Path $CsvOutput -NoTypeInformation -Encoding utf8
Write-Log -Level Info -Message "Results exported to $CsvOutput"

$FailedCount = @($Results | Where-Object { $_.Result -eq 'Failed' }).Count
if ($FailedCount -gt 0) {
    Write-Log -Level Warning -Message "$FailedCount zone(s) failed to update. Review the log and CSV for details."
}

Write-Log -Level Info -Message 'Script finished.'
```

- [ ] **Step 2: Validate the file still parses**

Run:

```bash
pwsh -NoProfile -Command "\$errors = \$null; [System.Management.Automation.Language.Parser]::ParseFile('/Users/michael/Documents/Git/PowerShell/Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1', [ref]\$null, [ref]\$errors) | Out-Null; if (\$errors) { \$errors } else { 'No syntax errors' }"
```

Expected: `No syntax errors`

- [ ] **Step 3: Commit**

```bash
cd "/Users/michael/Documents/Git/PowerShell"
git add "Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1"
git commit -m "$(cat <<'EOF'
Report IP verification for every zone on Add runs, drop early-exit

-RemoveNameServer keeps its exact existing behavior and CSV schema.
-AddNameServer no longer exits early when no NS records need adding -
it now always reports IP verification status (Matched/Mismatch/NotFound)
for every candidate zone in both the console summary and the exported
CSV, which gains IPVerificationStatus/IPVerificationDetail columns.

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 4: Update README.md to document the new Add behavior

**Files:**
- Modify: `Active Directory/Update-DNSNameServer/README.md`
- Test: none (documentation only)

- [ ] **Step 1: Update the `NameServerIPAddress` row in the Parameters table**

In `/Users/michael/Documents/Git/PowerShell/Active Directory/Update-DNSNameServer/README.md`, find:

```markdown
| `NameServerIPAddress`  | No        | Add            | IP address of the new DC. Used only to verify/log whether a matching A record already exists - no A records are created or modified. |
```

Replace with:

```markdown
| `NameServerIPAddress`  | Yes       | Add            | IP address of the new DC. Checked against each zone's A record to report a per-zone `IPVerificationStatus` (see below) - no A records are created or modified. |
```

- [ ] **Step 2: Replace the "How It Works" section**

Find:

```markdown
## How It Works

1. **Domain controller check**: confirms the local machine's `DomainRole` is a primary or backup domain controller; stops otherwise.
2. **Module check**: confirms the `DnsServer` module is available; stops with install guidance otherwise.
3. **Zone enumeration**: retrieves forward lookup zones from the target DNS server, always excluding `TrustAnchors`, then applies `ZoneName`/`ExcludeZone` filters if given.
4. **Existing state check**: for each candidate zone, reads the current NS records and determines whether the target host is already present or absent. Zones that don't need a change are skipped and logged.
5. **Summary and confirmation**: displays the zones that will actually change and prompts for confirmation (unless `-Force`).
6. **Execution**: adds or removes the NS record on each zone that needs it, via `Add-DnsServerResourceRecord` / `Remove-DnsServerResourceRecord`.
7. **Output**: writes a timestamped log file and a CSV of per-zone results.
```

Replace with:

```markdown
## How It Works

1. **Domain controller check**: confirms the local machine's `DomainRole` is a primary or backup domain controller; stops otherwise.
2. **Module check**: confirms the `DnsServer` module is available; stops with install guidance otherwise.
3. **Zone enumeration**: retrieves forward lookup zones from the target DNS server, always excluding `TrustAnchors`, then applies `ZoneName`/`ExcludeZone` filters if given.
4. **Existing state check**: for each candidate zone, reads the current NS records and determines whether the target host is already present or absent. On `-AddNameServer` runs, also checks (read-only) whether the host's A record exists in that zone and matches `-NameServerIPAddress`, recording a `Matched` / `Mismatch` / `NotFound` status for every candidate zone - including zones where the NS record was already present.
5. **Summary and confirmation**: displays the zones whose NS record will actually change and prompts for confirmation (unless `-Force`). On `-AddNameServer` runs, if no zone needs the NS record added, this step is skipped (no prompt) and the script proceeds straight to IP verification reporting instead of exiting.
6. **Execution**: adds or removes the NS record on each zone that needs it, via `Add-DnsServerResourceRecord` / `Remove-DnsServerResourceRecord`.
7. **IP verification summary** *(`-AddNameServer` only)*: prints how many zones verified successfully and lists any zone whose A record is still missing or doesn't match the supplied IP, so you know what still needs to catch up via dynamic DNS registration.
8. **Output**: writes a timestamped log file and a CSV of per-zone results.
```

- [ ] **Step 3: Replace the "CSV columns" section**

Find:

```markdown
### CSV columns

| Column          | Description                                      |
|-----------------|---------------------------------------------------|
| ZoneName        | Forward lookup zone name                          |
| Action          | `Add` or `Remove`                                  |
| PreviousState   | Whether the name server was `Present` or `Absent` before the change |
| Result          | `Success` or `Failed`                              |
| Message         | Detail message or error text                       |
| Timestamp       | Time the change was attempted                      |
```

Replace with:

```markdown
### CSV columns

**`-RemoveNameServer` runs** (only zones where the NS record was actually removed):

| Column          | Description                                      |
|-----------------|---------------------------------------------------|
| ZoneName        | Forward lookup zone name                          |
| Action          | Always `Remove`                                    |
| PreviousState   | Whether the name server was `Present` or `Absent` before the change |
| Result          | `Success` or `Failed`                              |
| Message         | Detail message or error text                       |
| Timestamp       | Time the change was attempted                      |

**`-AddNameServer` runs** (every candidate zone, whether or not its NS record needed adding):

| Column                | Description                                      |
|-----------------------|---------------------------------------------------|
| ZoneName              | Forward lookup zone name                          |
| Action                | Always `Add`                                       |
| PreviousState         | Whether the name server was `Present` or `Absent` before this run |
| Result                | `Success`, `Failed`, or `Skipped` (NS record already present) |
| Message               | Detail message or error text                       |
| IPVerificationStatus  | `Matched`, `Mismatch`, or `NotFound` - whether the DC's A record was found and matches `-NameServerIPAddress` |
| IPVerificationDetail  | Human-readable detail behind the verification status |
| Timestamp             | Time the row was recorded                          |
```

- [ ] **Step 4: Update the informational note about `-NameServerIPAddress`**

Find:

```markdown
- `-NameServerIPAddress` is informational only for the Add action (used to
  log whether an existing A record matches); it has no effect on Remove.
```

Replace with:

```markdown
- `-NameServerIPAddress` is required for the Add action and drives the
  IPVerificationStatus check (used to confirm whether the DC's A record has
  appeared and matches); it has no effect on Remove and never causes an A
  record to be created or modified.
```

- [ ] **Step 5: Commit**

```bash
cd "/Users/michael/Documents/Git/PowerShell"
git add "Active Directory/Update-DNSNameServer/README.md"
git commit -m "$(cat <<'EOF'
Document Add-side IP verification behavior in README

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

---

### Task 5: Full-script validation

**Files:**
- Read only: `Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1`
- Test: none (no test framework in scope per spec; manual trace-through)

- [ ] **Step 1: Parse the final file**

Run:

```bash
pwsh -NoProfile -Command "\$errors = \$null; [System.Management.Automation.Language.Parser]::ParseFile('/Users/michael/Documents/Git/PowerShell/Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1', [ref]\$null, [ref]\$errors) | Out-Null; if (\$errors) { \$errors } else { 'No syntax errors' }"
```

Expected: `No syntax errors`

- [ ] **Step 2: Trace through three scenarios by reading the code (no live DC available)**

Read the full script and confirm, by tracing the branches manually:

1. **Remove, DC present on some zones**: `$RemoveNameServer` is `$true` -> enters the `if ($RemoveNameServer)` branch in Step 6 -> behaves exactly as the pre-change script (summary, confirm, remove, export `ZoneName/Action/PreviousState/Result/Message/Timestamp` CSV) -> `return`s before reaching the Add-flow code.
2. **Add, DC already an NS everywhere, IP not yet registered (the screenshot's green case)**: `$ToChange` is empty -> `$HasChanges` is `$false` -> Step 7 prints "Continuing with IP verification only" and skips the confirmation prompt -> Step 8's `foreach ($Item in $WorkItems)` loop hits the `else` branch for every zone (`Result = 'Skipped'`) and carries forward each zone's `IPVerificationStatus` (expected `NotFound` for this case) -> Step 9 prints the verification summary listing those zones in yellow -> Step 10 exports the CSV. Confirm the script does **not** `return` early and does **not** call `Add-DnsServerResourceRecord` anywhere in this path.
3. **Add, DC missing from some zones, IP already registered**: `$ToChange` is non-empty -> `$HasChanges` is `$true` -> Step 7 shows the "will change" list and prompts -> Step 8 calls `Add-DnsServerResourceRecord` for `NeedsChange` items and marks others `Skipped`, with every item (changed or not) carrying its own `IPVerificationStatus` (expected `Matched`) -> Step 9/10 as above.

Confirm no step references `$ARecordNote` or `$NSResult`/`$NSMessage` (naming used only during design discussion, not in the final code - the implemented field names are `Result`/`Message`/`IPVerificationStatus`/`IPVerificationDetail`).

- [ ] **Step 3: Fix and commit if anything is wrong**

If the trace in Step 2 turns up a mismatch against this plan or the spec, fix it directly in `/Users/michael/Documents/Git/PowerShell/Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1`, re-run Step 1, then:

```bash
cd "/Users/michael/Documents/Git/PowerShell"
git add "Active Directory/Update-DNSNameServer/Update-DNSNameServer.ps1"
git commit -m "$(cat <<'EOF'
Fix issue found during final validation trace-through

Co-Authored-By: Claude Sonnet 5 <noreply@anthropic.com>
EOF
)"
```

If nothing is found, no commit is needed for this task.
