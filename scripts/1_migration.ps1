# BBS -> GitHub parallel migration runner (GitHub Actions optimized)
# - Configurable via parameters for GitHub Actions workflow
# - Writes per-repo logs and a repo_migration_output-*.csv
# - Robust parallel Receive-Job parsing

param(
    [Parameter(Mandatory=$false)]
    [int]$MaxConcurrent = 3,

    [Parameter(Mandatory=$false)]
    [string]$CsvPath = "repos.csv",

    [Parameter(Mandatory=$false)]
    [string]$OutputPath = ""
)

# ---- Settings ----
if ($MaxConcurrent -gt 5) {
    Write-Host "[ERROR] Maximum concurrent migrations ($MaxConcurrent) exceeds 5." -ForegroundColor Red
    exit 1
}
if ($MaxConcurrent -lt 1) {
    Write-Host "[ERROR] MaxConcurrent must be at least 1." -ForegroundColor Red
    exit 1
}

$timestamp = Get-Date -Format 'yyyyMMdd-HHmmss'
$outputCsvPath = if ([string]::IsNullOrWhiteSpace($OutputPath)) { "repo_migration_output-$timestamp.csv" } else { $OutputPath }

if (-not (Test-Path -Path $CsvPath)) {
    Write-Host "[ERROR] CSV file not found at path: $CsvPath" -ForegroundColor Red
    exit 1
}
$src = Import-Csv -Path $CsvPath
if ($src.Count -eq 0) {
    Write-Host "[ERROR] CSV file is empty: $CsvPath" -ForegroundColor Red
    exit 1
}

# Validate columns (Bitbucket inventory + GitHub mapping)
$requiredColumns = @('project-key','project-name','repo','github_org','github_repo','gh_repo_visibility')
$missingColumns = $requiredColumns | Where-Object { $_ -notin $src[0].PSObject.Properties.Name }
if ($missingColumns) {
    Write-Host "[ERROR] CSV is missing required columns: $($missingColumns -join ', ')" -ForegroundColor Red
    exit 1
}

# Prepare working array & status columns
$REPOS = New-Object System.Collections.ArrayList
foreach ($r in $src) {
    if ($r.PSObject.Properties["Migration_Status"]) { $r.Migration_Status = "Pending" } else { $r | Add-Member -NotePropertyName Migration_Status -NotePropertyValue "Pending" }
    if ($r.PSObject.Properties["Log_File"])        { $r.Log_File        = ""       } else { $r | Add-Member -NotePropertyName Log_File        -NotePropertyValue ""       }
    [void]$REPOS.Add($r)
}

function Write-MigrationStatusCsv { $REPOS | Export-Csv -Path $outputCsvPath -NoTypeInformation }

Write-MigrationStatusCsv
Write-Host "[INFO] Starting migration with $MaxConcurrent concurrent jobs..."
Write-Host "[INFO] Processing $($REPOS.Count) repositories from: $CsvPath" -ForegroundColor Cyan
Write-Host "[INFO] Initialized migration status output: $outputCsvPath" -ForegroundColor Cyan

# ---- Globals & status ----
$queue      = [System.Collections.ArrayList]@($REPOS)
$inProgress = [System.Collections.ArrayList]@()
$migrated   = [System.Collections.ArrayList]@()
$failed     = [System.Collections.ArrayList]@()
$script:StatusLineWidth = 0

function Show-StatusBar {
    param($queue, $inProgress, $migrated, $failed)
    $statusLine = ("QUEUE: {0} | IN PROGRESS: {1} | MIGRATED: {2} | MIGRATION FAILED: {3}" -f $queue.Count, $inProgress.Count, $migrated.Count, $failed.Count)
    if ($statusLine.Length -gt $script:StatusLineWidth) { $script:StatusLineWidth = $statusLine.Length }
    Write-Host ("`r" + $statusLine.PadRight($script:StatusLineWidth)) -NoNewline -ForegroundColor Cyan
}

# ---- Main loop ----
while ($queue.Count -gt 0 -or $inProgress.Count -gt 0) {
    # Start new jobs if below max concurrent
    while ($inProgress.Count -lt $MaxConcurrent -and $queue.Count -gt 0) {
        $repo = $queue[0]; $queue.RemoveAt(0)

        $projectKey   = $repo.'project-key'
        $projectName  = $repo.'project-name'
        $bbsRepoSlug  = $repo.'repo'
        $githubOrg    = $repo.'github_org'
        $githubRepo   = $repo.'github_repo'
        $visibility   = $repo.'gh_repo_visibility'   # public|private|internal

        $logFile = "migration-$githubRepo-$(Get-Date -Format 'yyyyMMdd-HHmmss').txt"
        $repo.Log_File = $logFile
        Write-MigrationStatusCsv

        $scriptBlock = {
            param($projectKey, $bbsRepoSlug, $githubOrg, $githubRepo, $visibility, $logFile)

            function Migrate-Repo {
                param($projectKey, $bbsRepoSlug, $githubOrg, $githubRepo, $visibility, $logFile)

                # Compose command for bbs2gh migrate-repo
                $bbsUrl = $env:BBS_BASE_URL
                if (-not $bbsUrl) {
                    "[{0}] [ERROR] BBS_BASE_URL is not set" -f (Get-Date) | Tee-Object -FilePath $logFile -Append | Out-Null
                    return $false
                }

                "[{0}] [START] Migration: {1}/{2} -> {3}/{4} (visibility: {5})" -f (Get-Date), $projectKey, $bbsRepoSlug, $githubOrg, $githubRepo, $visibility |
                    Tee-Object -FilePath $logFile -Append | Out-Null

                $cmd = @(
                    "gh bbs2gh migrate-repo",
                    "--bbs-server-url `"$bbsUrl`"",
                    "--bbs-project `"$projectKey`"",
                    "--bbs-repo `"$bbsRepoSlug`"",
                    "--github-org `"$githubOrg`"",
                    "--github-repo `"$githubRepo`"",
                    "--ssh-user "yashtnaik"",
                    "--ssh-private-key "server.pub"",
                    "--use-github-storage",
                    "--target-repo-visibility `"$visibility`""
                ) -join " "

                "[{0}] [DEBUG] Running: {1}" -f (Get-Date), $cmd | Tee-Object -FilePath $logFile -Append | Out-Null

                # Provide credentials via env (GH_PAT, BBS_USERNAME, BBS_PASSWORD)
                & gh bbs2gh migrate-repo `
                    --bbs-server-url $bbsUrl `
                    --bbs-project $projectKey `
                    --bbs-repo $bbsRepoSlug `
                    --github-org $githubOrg `
                    --github-repo $githubRepo `
                    --use-github-storage `
                    --ssh-user yashtnaik `
                    --ssh-private-key server.pub"
                    --target-repo-visibility $visibility *>&1 | Tee-Object -FilePath $logFile -Append | Out-Null

                $exit = $LASTEXITCODE
                if ($exit -eq 0) {
                    "[{0}] [SUCCESS] Migration: {1}/{2} -> {3}/{4}" -f (Get-Date), $projectKey, $bbsRepoSlug, $githubOrg, $githubRepo |
                        Tee-Object -FilePath $logFile -Append | Out-Null
                    return $true
                } else {
                    "[{0}] [FAILED] Migration: {1}/{2} -> {3}/{4} (exit: {5})" -f (Get-Date), $projectKey, $bbsRepoSlug, $githubOrg, $githubRepo, $exit |
                        Tee-Object -FilePath $logFile -Append | Out-Null
                    return $false
                }
            }

            $ok = Migrate-Repo -projectKey $projectKey -bbsRepoSlug $bbsRepoSlug -githubOrg $githubOrg -githubRepo $githubRepo -visibility $visibility -logFile $logFile
            return @{ MigrationSuccess = $ok }
        }

        $job = Start-Job -ScriptBlock $scriptBlock -ArgumentList $projectKey, $bbsRepoSlug, $githubOrg, $githubRepo, $visibility, $logFile
        $null = $inProgress.Add([PSCustomObject]@{ Job = $job; Repo = $repo; LogFile = $logFile; LastOutputLength = 0 })
        Show-StatusBar -queue $queue -inProgress $inProgress -migrated $migrated -failed $failed
    }

    # Stream new output shards from each log file
    foreach ($item in @($inProgress)) {
        if (Test-Path -Path $item.LogFile) {
            try {
                $content = Get-Content -Path $item.LogFile -Raw
                $newLen = $content.Length
                if ($newLen -gt $item.LastOutputLength) {
                    $delta = $content.Substring($item.LastOutputLength)
                    $item.LastOutputLength = $newLen
                    if ($delta) {
                        Write-Host ""
                        $delta.TrimEnd("`r","`n") -split "(`r`n|`n|`r)" | ForEach-Object { if ($_ -ne '') { Write-Host $_ } }
                        Show-StatusBar -queue $queue -inProgress $inProgress -migrated $migrated -failed $failed
                    }
                }
            } catch { }
        }
    }

    # Receive results and update CSV
    foreach ($item in @($inProgress)) {
        if ($item.Job.State -in 'Completed','Failed','Stopped') {
            $jobOutput = Receive-Job -Job $item.Job
            Remove-Job -Job $item.Job
            $result = $jobOutput | Where-Object { $_ -is [hashtable] -and $_.ContainsKey('MigrationSuccess') } | Select-Object -Last 1

            if ($null -eq $result) {
                $null = $failed.Add($item.Repo); $item.Repo.Migration_Status = "Failure"
            } elseif ($result.MigrationSuccess -eq $true) {
                $null = $migrated.Add($item.Repo); $item.Repo.Migration_Status = "Success"
            } else {
                $null = $failed.Add($item.Repo); $item.Repo.Migration_Status = "Failure"
            }

            Write-MigrationStatusCsv
            $inProgress.Remove($item)
            Show-StatusBar -queue $queue -inProgress $inProgress -migrated $migrated -failed $failed
        }
    }

    Start-Sleep -Seconds 5
}

Write-Host "`n[INFO] All migrations completed."
Write-Host "[SUMMARY] Total: $($REPOS.Count) | Migrated: $($migrated.Count) | Failed: $($failed.Count) " -ForegroundColor Green
Write-MigrationStatusCsv
Write-Host "[INFO] Wrote migration results with Migration_Status column: $outputCsvPath" -ForegroundColor Cyan

# Warning only; let workflow handle failure logic
if ($failed.Count -gt 0) {
    Write-Host "[WARNING] Migration completed with $($failed.Count) failures" -ForegroundColor Yellow
}
