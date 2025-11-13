# BBS → GH Migration Validation Script (console-friendly + per-repo table summary)
# Uses ONLY the provided BbsBaseUrl for Bitbucket REST calls and ignores any host in CSV 'url'.
# Expects CSV header with: project-key, repo, url, github_org, github_repo

[CmdletBinding()]
param(
  [string]$CsvPath,
  [string]$BbsBaseUrl
)

# Ensure ANSI colors render in GitHub logs (Windows runners)
if (-not $env:TERM) { $env:TERM = 'xterm' }

# ANSI color helpers
$GREEN = "`e[32m"
$RED   = "`e[31m"
$CYAN  = "`e[36m"
$GRAY  = "`e[90m"
$RESET = "`e[0m"

Add-Type -AssemblyName System.Web

$LOG_FILE = "validation-log-$(Get-Date -Format 'yyyyMMdd').txt"

# Accumulator for per-repo table
$global:RepoSummaries = New-Object System.Collections.Generic.List[object]

function Get-BbsHeaders {
  if ($env:BBS_AUTH_TYPE -and $env:BBS_AUTH_TYPE.Trim().ToLower() -eq 'basic') {
    if (-not $env:BBS_USERNAME -or -not $env:BBS_PASSWORD) {
      throw "BBS_AUTH_TYPE=Basic requires BBS_USERNAME and BBS_PASSWORD."
    }
    $bytes = [Text.Encoding]::ASCII.GetBytes("$($env:BBS_USERNAME):$($env:BBS_PASSWORD)")
    $basic = [Convert]::ToBase64String($bytes)
    return @{ Authorization = "Basic $basic" }
  }
  if ($env:BBS_TOKEN) {
    return @{ Authorization = "Bearer $($env:BBS_TOKEN)" }
  }
  throw "Provide Bitbucket credentials via BBS_TOKEN (preferred) or set BBS_AUTH_TYPE=Basic with BBS_USERNAME/BBS_PASSWORD."
}

function Get-BbsBaseUrl() {
  if (-not $BbsBaseUrl) { throw "BbsBaseUrl is required" }
  return $BbsBaseUrl.TrimEnd('/')
}

function Get-BbsBranches([string]$baseUrl, [string]$projectKey, [string]$repoSlug, [hashtable]$headers) {
  $branches = @()
  $start = 0
  do {
    $endpoint = "$baseUrl/rest/api/1.0/projects/$projectKey/repos/$repoSlug/branches?limit=500&start=$start"
    $resp = Invoke-RestMethod -Uri $endpoint -Headers $headers -Method Get
    $branches += ($resp.values | ForEach-Object { $_.displayId })
    $isLast = $resp.isLastPage
    $start  = $resp.nextPageStart
  } while (-not $isLast)
  return $branches
}

function Get-BbsCommitsInfo([string]$baseUrl, [string]$projectKey, [string]$repoSlug, [string]$branch, [hashtable]$headers) {
  $total = 0
  $latest = ""
  $start = 0
  $limit = 1000
  do {
    $encBranch = [System.Web.HttpUtility]::UrlEncode($branch)
    $endpoint = "$baseUrl/rest/api/1.0/projects/$projectKey/repos/$repoSlug/commits?until=$encBranch&limit=$limit&start=$start"
    $resp = Invoke-RestMethod -Uri $endpoint -Headers $headers -Method Get
    if (-not $latest -and $resp.values.Count -gt 0) { $latest = $resp.values[0].id }
    $total += $resp.values.Count
    $isLast = $resp.isLastPage
    $start  = $resp.nextPageStart
  } while (-not $isLast)
  return [pscustomobject]@{ Count = $total; Latest = $latest }
}

# ---- GH helpers (safe, no error spam) ----
function Test-GhRepoExists([string]$org, [string]$repo) {
  try {
    gh api -X GET "/repos/$org/$repo" | Out-Null
    return $true
  } catch {
    return $false
  }
}

function Get-GhBranchesSafe([string]$org, [string]$repo) {
  try {
    $json = gh api "/repos/$org/$repo/branches" --paginate | ConvertFrom-Json
    return $json | ForEach-Object { $_.name }
  } catch {
    return @()
  }
}

function Get-GhCommitsInfoSafe([string]$org, [string]$repo, [string]$branch) {
  try {
    $total = 0; $latest = ""; $page = 1; $perPage = 100
    do {
      $encBranch = [System.Web.HttpUtility]::UrlEncode($branch)
      $chunk = gh api "/repos/$org/$repo/commits?sha=$encBranch&page=$page&per_page=$perPage" | ConvertFrom-Json
      if ($page -eq 1 -and $chunk.Count -gt 0) { $latest = $chunk[0].sha }
      $total += $chunk.Count; $page++
    } while ($chunk.Count -eq $perPage)
    return [pscustomobject]@{ Count = $total; Latest = $latest }
  } catch {
    return [pscustomobject]@{ Count = 0; Latest = "" }
  }
}

function Status-Marker([bool]$ok) {
  if ($ok) { return "${GREEN}✅ Matching${RESET}" }
  else     { return "${RED}❌ Not Matching${RESET}" }
}

function Validate-Migration {
  param(
    [string]$bbsProjectKey,
    [string]$bbsRepoSlug,
    [string]$bbsRepoUrl,
    [string]$githubOrg,
    [string]$githubRepo
  )

  $header = "[{0}] Validating migration: {1}/{2}  (BBS: {3}/{4})" -f (Get-Date), $githubOrg, $githubRepo, $bbsProjectKey, $bbsRepoSlug
  Write-Host $header
  $header | Tee-Object -FilePath $LOG_FILE -Append | Out-Null

  # Optional GH repo snapshot (artifact)
  try {
    gh repo view "$githubOrg/$githubRepo" --json createdAt,diskUsage,defaultBranchRef,isPrivate `
      | Out-File -FilePath "validation-$githubRepo.json"
  } catch { }

  $headers = Get-BbsHeaders
  $baseUrl = Get-BbsBaseUrl

  # --- Branch set comparison ---
  $ghExists = Test-GhRepoExists -org $githubOrg -repo $githubRepo
  if (-not $ghExists) {
    $warn = "[{0}] GitHub repo not found or inaccessible: {1}/{2}. Treating GH side as empty." -f (Get-Date), $githubOrg, $githubRepo
    Write-Host $warn
    $warn | Tee-Object -FilePath $LOG_FILE -Append | Out-Null
    $ghBranches = @()
  } else {
    $ghBranches = Get-GhBranchesSafe -org $githubOrg -repo $githubRepo
  }

  $bbsBranches = Get-BbsBranches -baseUrl $baseUrl -projectKey $bbsProjectKey -repoSlug $bbsRepoSlug -headers $headers
  $ghBranchCount  = $ghBranches.Count
  $bbsBranchCount = $bbsBranches.Count
  $branchCountOk  = ($ghBranchCount -eq $bbsBranchCount)

  $line = ("[{0}] Branch Count: {1}BBS={2}{3} | {1}GitHub={4}{3} | {5}" -f `
    (Get-Date), $CYAN, $bbsBranchCount, $RESET, $ghBranchCount, (Status-Marker $branchCountOk))
  Write-Host $line
  $line | Tee-Object -FilePath $LOG_FILE -Append | Out-Null

  $missingInGH  = $bbsBranches | Where-Object { $_ -notin $ghBranches }
  $missingInBBS = $ghBranches  | Where-Object { $_ -notin $bbsBranches }

  if ($missingInGH.Count -gt 0) {
    $msg = "[{0}] Branches missing in GitHub: {1}" -f (Get-Date), ($missingInGH -join ', ')
    Write-Host $msg
    $msg | Tee-Object -FilePath $LOG_FILE -Append | Out-Null
  }
  if ($missingInBBS.Count -gt 0) {
    $msg = "[{0}] Branches missing in Bitbucket: {1}" -f (Get-Date), ($missingInBBS -join ', ')
    Write-Host $msg
    $msg | Tee-Object -FilePath $LOG_FILE -Append | Out-Null
  }

  # --- Per-branch details for common branches ---
  $allCommitCountsMatch = $true
  $allLatestShasMatch   = $true

  foreach ($branch in ($ghBranches | Where-Object { $_ -in $bbsBranches })) {
    $ghInfo  = Get-GhCommitsInfoSafe -org $githubOrg -repo $githubRepo -branch $branch
    $bbsInfo = Get-BbsCommitsInfo    -baseUrl $baseUrl -projectKey $bbsProjectKey -repoSlug $bbsRepoSlug -branch $branch -headers $headers

    $countOk = ($ghInfo.Count -eq $bbsInfo.Count)
    $shaOk   = ($ghInfo.Latest -eq $bbsInfo.Latest)

    if (-not $countOk) { $allCommitCountsMatch = $false }
    if (-not $shaOk)   { $allLatestShasMatch   = $false }

    $countLine = ("[{0}] Branch '{1}': {2}BBS Commits={3}{4} | {2}GitHub Commits={5}{4} | {6}" -f `
      (Get-Date), $branch, $CYAN, $bbsInfo.Count, $RESET, $ghInfo.Count, (Status-Marker $countOk))
    Write-Host $countLine
    $countLine | Tee-Object -FilePath $LOG_FILE -Append | Out-Null

    $shaLine =   ("[{0}] Branch '{1}': {2}BBS SHA={3}{4} | {2}GitHub SHA={5}{4} | {6}" -f `
      (Get-Date), $branch, $CYAN, ($bbsInfo.Latest ?? ''), $RESET, ($ghInfo.Latest ?? ''), (Status-Marker $shaOk))
    Write-Host $shaLine
    $shaLine | Tee-Object -FilePath $LOG_FILE -Append | Out-Null
  }

  $done = "[{0}] Validation complete for {1}/{2}" -f (Get-Date), $githubOrg, $githubRepo
  Write-Host $done
  $done | Tee-Object -FilePath $LOG_FILE -Append | Out-Null

  # Per-repo summary row for table
  $summaryObj = [pscustomobject]@{
    github_org          = $githubOrg
    github_repo         = $githubRepo
    bbs_project_key     = $bbsProjectKey
    bbs_repo            = $bbsRepoSlug
    branch_count_bbs    = $bbsBranchCount
    branch_count_gh     = $ghBranchCount
    branch_count_match  = $branchCountOk
    commits_match_all   = $allCommitCountsMatch
    shas_match_all      = $allLatestShasMatch
  }
  $global:RepoSummaries.Add($summaryObj) | Out-Null
}

function Validate-FromCSV {
  param([string]$csvPath)

  if (-not (Test-Path $csvPath)) {
    $e = "[{0}] ERROR: CSV file not found: {1}" -f (Get-Date), $csvPath
    Write-Host $e
    $e | Tee-Object -FilePath $LOG_FILE -Append | Out-Null
    return
  }

  $repos = Import-Csv -Path $csvPath

  # Validate columns
  $required = @('project-key','repo','url','github_org','github_repo')
  $cols = $repos[0].PSObject.Properties.Name
  $missing = $required | Where-Object { $_ -notin $cols }
  if ($missing.Count -gt 0) {
    throw ("Missing required columns in CSV: {0}" -f ($missing -join ', '))
  }

  foreach ($repo in $repos) {
    $bbsProjectKey = $repo.'project-key'
    $bbsRepoSlug   = $repo.repo
    $bbsUrl        = $repo.url  # kept for logging/trace; not used for base URL
    $ghOrg         = $repo.github_org
    $ghRepo        = $repo.github_repo

    $processing = "[{0}] Processing: {1}{2}/{3}{4} -> {1}{5}/{6}{4}" -f `
      (Get-Date), $CYAN, $bbsProjectKey, $repo.repo, $RESET, $ghOrg, $ghRepo
    Write-Host $processing
    $processing | Tee-Object -FilePath $LOG_FILE -Append | Out-Null

    Validate-Migration -bbsProjectKey $bbsProjectKey `
                       -bbsRepoSlug   $bbsRepoSlug   `
                       -bbsRepoUrl    $bbsUrl        `
                       -githubOrg     $ghOrg         `
                       -githubRepo    $ghRepo
  }

  $allDone = "[{0}] All validations from CSV completed" -f (Get-Date)
  Write-Host $allDone
  $allDone | Tee-Object -FilePath $LOG_FILE -Append | Out-Null

  # Write CSV + Markdown table for the summary
  if ($global:RepoSummaries.Count -gt 0) {
    $csvPathOut = "validation-summary.csv"
    $global:RepoSummaries | Export-Csv -Path $csvPathOut -NoTypeInformation -Encoding UTF8

    $rows = $global:RepoSummaries
    $md   = @()
    $md  += "| GitHub Repo | BBS Repo | Branch Count (BBS/GH) | Branch Count Match | All Commit Counts Match | All Latest SHAs Match |"
    $md  += "|-------------|---------|------------------------|--------------------|-------------------------|-----------------------|"
    foreach ($r in $rows) {
      $repoGh = "$($r.github_org)/$($r.github_repo)"
      $repoBb = "$($r.bbs_project_key)/$($r.bbs_repo)"
      $bc     = "$($r.branch_count_bbs)/$($r.branch_count_gh)"
      $bcOk   = if ($r.branch_count_match) { "✅" } else { "❌" }
      $ccOk   = if ($r.commits_match_all)  { "✅" } else { "❌" }
      $shaOk  = if ($r.shas_match_all)     { "✅" } else { "❌" }
      $md    += "| $repoGh | $repoBb | $bc | $bcOk | $ccOk | $shaOk |"
    }
    $md | Out-File -FilePath "validation-summary.md" -Encoding UTF8
  }
}

# Entrypoint
if (-not $CsvPath)    { throw "CsvPath is required" }
if (-not $BbsBaseUrl) { throw "BbsBaseUrl is required" }
Validate-FromCSV -csvPath $CsvPath
