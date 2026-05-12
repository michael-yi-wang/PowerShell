#Requires -Version 7.0

<#
.SYNOPSIS
    Helpdesk wrapper that queues the SPO stale-user removal pipeline in Azure
    DevOps via the REST API, without requiring the operator to open a browser.

.DESCRIPTION
    Reads pipeline connection details from machine-scope environment variables
    (provisioned by Intune/GPO) and prompts the operator for the SharePoint site
    URL and the user UPN to process. It then calls the ADO Pipelines REST API to
    queue a run and prints the resulting run URL.

    Stage 1 (CheckOnly) runs automatically. Stage 2 (removal) waits for approval
    from the designated IT manager in the 'SPO-Helpdesk-Approval' environment.

    REQUIRED ENVIRONMENT VARIABLES (set by Intune — do NOT store in this script)
    --------------------------------------------------------------------------
    ADO_ORG_URL       Azure DevOps organisation URL
                      e.g. https://dev.azure.com/contoso
    ADO_PROJECT       Azure DevOps project name
                      e.g. IT-Operations
    ADO_PIPELINE_ID   Integer ID of the pipeline (visible in the pipeline URL)
    ADO_PAT           Personal Access Token with 'Build: Queue' scope only

.EXAMPLE
    .\Invoke-SPOPipeline.ps1

    Runs the interactive wrapper. No parameters are accepted — all configuration
    comes from environment variables, and all inputs are collected via prompts.

.NOTES
    Author   : Michael Wang
    Version  : 1.0.0
    Requires : PowerShell 7.0+

    No secrets, tenant IDs, app IDs, or URLs are hardcoded in this script.
    All sensitive values are read at runtime from machine-scope environment
    variables configured by your IT administrator.

    PAT security: create the PAT under a dedicated helpdesk service account.
    Scope it to 'Build: Queue (Read and execute)' only. Set a short expiry
    (e.g. 90 days) and rotate it before it expires. Update ADO_PAT on all
    helpdesk machines via Intune when rotating.
#>

[CmdletBinding()]
param ()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

#region Logging

function Write-Log {
    <#
    .SYNOPSIS
        Writes a timestamped, colour-coded message to the console.
        This wrapper script is interactive-only, so no file logging is used.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Message,

        [ValidateSet('Info', 'Warning', 'Error')]
        [string]$Level = 'Info'
    )

    $timestamp = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $entry     = "[$timestamp] [$($Level.ToUpper().PadRight(7))] $Message"

    $color = switch ($Level) {
        'Info'    { 'Green'  }
        'Warning' { 'Yellow' }
        'Error'   { 'Red'    }
    }
    Write-Host $entry -ForegroundColor $color
}

#endregion

#region URL Validation

function Test-SPOSiteCollectionUrl {
    <#
    .SYNOPSIS
        Returns $true if the URL matches a valid SPO site collection pattern.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Url
    )

    $trimmed = $Url.TrimEnd('/')
    return $trimmed -match '^https://[a-zA-Z0-9][a-zA-Z0-9-]*(-my)?\.sharepoint\.com(/sites/[^/]+|/teams/[^/]+|/portals/[^/]+|/personal/[^/]+)?$'
}

#endregion

#region Banner

function Show-Banner {
    Write-Host ''
    Write-Host '  +====================================================+' -ForegroundColor Cyan
    Write-Host '  |   SPO Stale-User Removal  -  Helpdesk Launcher     |' -ForegroundColor Cyan
    Write-Host '  |   Powered by Azure DevOps Pipelines                |' -ForegroundColor Cyan
    Write-Host '  +====================================================+' -ForegroundColor Cyan
    Write-Host ''
    Write-Host '  This tool queues a two-stage pipeline:' -ForegroundColor White
    Write-Host '    Stage 1 — Finds and displays the stale user profile.' -ForegroundColor DarkGray
    Write-Host '    Stage 2 — Removes the user (requires manager approval).' -ForegroundColor DarkGray
    Write-Host ''
}

#endregion

#region Environment Variable Check

function Get-RequiredEnvVar {
    <#
    .SYNOPSIS
        Reads a required environment variable and returns its value.
        Returns $null (without throwing) so the caller can collect all
        missing vars before printing a single combined error.
    #>
    param (
        [Parameter(Mandatory)]
        [string]$Name
    )

    $value = [System.Environment]::GetEnvironmentVariable($Name)
    if ([string]::IsNullOrWhiteSpace($value)) {
        return $null
    }
    return $value
}

function Assert-EnvironmentVariables {
    <#
    .SYNOPSIS
        Verifies all required environment variables are set. Exits with code 1
        if any are missing, printing a clear list of which ones to configure.
    #>

    $required = @('ADO_ORG_URL', 'ADO_PROJECT', 'ADO_PIPELINE_ID', 'ADO_PAT')
    $missing  = @()

    foreach ($varName in $required) {
        if ($null -eq (Get-RequiredEnvVar -Name $varName)) {
            $missing += $varName
        }
    }

    if ($missing.Count -gt 0) {
        Write-Host ''
        Write-Host '  [ERROR] The following required environment variables are not set:' `
            -ForegroundColor Red
        Write-Host ''
        foreach ($varName in $missing) {
            Write-Host "    - $varName" -ForegroundColor Yellow
        }
        Write-Host ''
        Write-Host '  Contact your IT administrator to have these configured on this machine.' `
            -ForegroundColor Cyan
        Write-Host ''
        exit 1
    }

    Write-Log -Message 'All required environment variables are present.'
}

#endregion

#region Input Prompts

function Read-SiteUrl {
    <#
    .SYNOPSIS
        Prompts the operator for a SharePoint site URL and loops until a valid
        URL is entered.
    #>
    [OutputType([string])]
    param ()

    Write-Host '  Accepted URL formats:' -ForegroundColor DarkGray
    Write-Host '    https://contoso.sharepoint.com' -ForegroundColor DarkGray
    Write-Host '    https://contoso.sharepoint.com/sites/finance' -ForegroundColor DarkGray
    Write-Host '    https://contoso.sharepoint.com/teams/marketing' -ForegroundColor DarkGray
    Write-Host ''

    while ($true) {
        $raw = (Read-Host '  Enter the SharePoint site URL').Trim().TrimEnd('/')

        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Host '  URL cannot be empty. Please try again.' -ForegroundColor Red
            continue
        }

        if (Test-SPOSiteCollectionUrl -Url $raw) {
            Write-Log -Message "Site URL accepted: $raw"
            return $raw
        }

        Write-Host '  Invalid URL. Must be a SharePoint Online site collection root URL.' `
            -ForegroundColor Red
        Write-Log -Message "Invalid site URL entered: $raw" -Level Warning
    }
}

function Read-UserUPN {
    <#
    .SYNOPSIS
        Prompts the operator for a user UPN and loops until a non-empty value
        is entered.
    #>
    [OutputType([string])]
    param ()

    while ($true) {
        $raw = (Read-Host '  Enter the User UPN (e.g. john.doe@contoso.com)').Trim()

        if ([string]::IsNullOrWhiteSpace($raw)) {
            Write-Host '  UPN cannot be empty. Please try again.' -ForegroundColor Red
            continue
        }

        Write-Log -Message "User UPN accepted: $raw"
        return $raw
    }
}

#endregion

#region ADO Pipeline Invocation

function Invoke-AdoPipelineRun {
    <#
    .SYNOPSIS
        Calls the Azure DevOps Pipelines REST API to queue a new run.
        Returns the run object on success, or throws on failure.
    #>
    [OutputType([pscustomobject])]
    param (
        [Parameter(Mandatory)]
        [string]$OrgUrl,

        [Parameter(Mandatory)]
        [string]$Project,

        [Parameter(Mandatory)]
        [string]$PipelineId,

        [Parameter(Mandatory)]
        [string]$Pat,

        [Parameter(Mandatory)]
        [string]$SiteUrl,

        [Parameter(Mandatory)]
        [string]$UserUPN
    )

    # Build Basic auth header from PAT (username is intentionally left blank).
    $tokenBytes  = [System.Text.Encoding]::UTF8.GetBytes(":$Pat")
    $base64Token = [System.Convert]::ToBase64String($tokenBytes)
    $headers     = @{
        Authorization  = "Basic $base64Token"
        'Content-Type' = 'application/json'
    }

    # API endpoint — pipelines runs API version 7.1.
    $apiUrl = "$($OrgUrl.TrimEnd('/'))/$([Uri]::EscapeDataString($Project))/_apis/pipelines/$PipelineId/runs?api-version=7.1"

    # Payload passes template parameters to the pipeline YAML.
    $body = @{
        templateParameters = @{
            SiteUrl = $SiteUrl
            UserUPN = $UserUPN
        }
    } | ConvertTo-Json -Depth 3

    Write-Log -Message "Queuing pipeline run via: $apiUrl"

    $response = Invoke-RestMethod -Uri $apiUrl `
                                  -Method Post `
                                  -Headers $headers `
                                  -Body $body `
                                  -ErrorAction Stop

    return $response
}

#endregion

#region Main

Show-Banner
Assert-EnvironmentVariables

# Read env vars (all validated above — guaranteed non-null here).
$orgUrl     = [System.Environment]::GetEnvironmentVariable('ADO_ORG_URL').TrimEnd('/')
$project    = [System.Environment]::GetEnvironmentVariable('ADO_PROJECT')
$pipelineId = [System.Environment]::GetEnvironmentVariable('ADO_PIPELINE_ID')
$pat        = [System.Environment]::GetEnvironmentVariable('ADO_PAT')

Write-Host ''
Write-Host '  --- Step 1: Site URL ---' -ForegroundColor White
$siteUrl = Read-SiteUrl

Write-Host ''
Write-Host '  --- Step 2: User UPN ---' -ForegroundColor White
$userUpn = Read-UserUPN

Write-Host ''
Write-Log -Message "Submitting pipeline run for site '$siteUrl' and user '$userUpn'."

try {
    $run = Invoke-AdoPipelineRun -OrgUrl      $orgUrl `
                                  -Project     $project `
                                  -PipelineId  $pipelineId `
                                  -Pat         $pat `
                                  -SiteUrl     $siteUrl `
                                  -UserUPN     $userUpn

    $runId  = $run.id
    $runUrl = "$orgUrl/$([Uri]::EscapeDataString($project))/_build/results?buildId=$runId"

    Write-Host ''
    Write-Host '  +----------------------------------------------------+' -ForegroundColor Green
    Write-Host '  |  Pipeline run queued successfully!                 |' -ForegroundColor Green
    Write-Host '  +----------------------------------------------------+' -ForegroundColor Green
    Write-Host "  |  Run ID : $runId"
    Write-Host "  |  Site   : $siteUrl"
    Write-Host "  |  User   : $userUpn"
    Write-Host '  +----------------------------------------------------+' -ForegroundColor Green
    Write-Host ''
    Write-Host "  Pipeline URL: $runUrl" -ForegroundColor Cyan
    Write-Host ''
    Write-Log -Message "Pipeline run #$runId queued. URL: $runUrl"

    $openBrowser = (Read-Host '  Open the pipeline in your browser? (Y/N)').Trim().ToUpper()
    if ($openBrowser -eq 'Y') {
        Start-Process $runUrl
    }
}
catch {
    $statusCode = $null
    if ($_.Exception.Response) {
        $statusCode = [int]$_.Exception.Response.StatusCode
    }

    Write-Host ''
    Write-Host '  +----------------------------------------------------+' -ForegroundColor Red
    Write-Host '  |  ERROR: Failed to queue the pipeline run.          |' -ForegroundColor Red
    Write-Host '  +----------------------------------------------------+' -ForegroundColor Red
    Write-Host ''
    Write-Host "  Error detail: $($_.Exception.Message)" -ForegroundColor Red
    if ($statusCode) {
        Write-Host "  HTTP status : $statusCode" -ForegroundColor Red
    }
    Write-Host ''
    Write-Host '  Troubleshooting hints:' -ForegroundColor Yellow
    Write-Host '    401 Unauthorized  — ADO_PAT may be expired or lack Build: Queue permission.' `
        -ForegroundColor Yellow
    Write-Host '    404 Not Found     — Verify ADO_PIPELINE_ID, ADO_PROJECT, and ADO_ORG_URL.' `
        -ForegroundColor Yellow
    Write-Host '    Connection error  — Check network connectivity to Azure DevOps.' `
        -ForegroundColor Yellow
    Write-Host ''
    Write-Host '  Contact your IT administrator with the error detail shown above.' `
        -ForegroundColor Cyan
    Write-Host ''

    Write-Log -Message "Pipeline API call failed: $($_.Exception.Message)" -Level Error
    exit 1
}

#endregion
