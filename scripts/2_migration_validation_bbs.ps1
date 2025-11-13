# BBS → GH Migration Validation Script
# Reads repos from CSV (expects header with: project-key, repo, url, github_org, github_repo)
# Compares branches and commits between Bitbucket Server/DC and GitHub.

[CmdletBinding()]
param(
  [string]$CsvPath,
  [string]$BbsBaseUrl
)

Add-Type -AssemblyName System.Web

$LOG_FILE = "validation-log-$(Get-Date -Format 'yyyyMMdd').txt"

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

function Compute-BbsBaseUrl([string]$repoUrl) {
  if ($BbsBaseUrl) { return $BbsBaseUrl.TrimEnd('/') }
  return ($repoUrl -replace '(?i)/projects/.*$','')
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

function Get-GhBranches([string]$org, [string]$repo) {
  $json = gh api "/repos/$org/$repo/branches" --paginate | ConvertFrom-Json
  return $json | ForEach-Object { $_.name }
}

function Get-GhCommitsInfo([string]$org, [string]$repo, [string]$branch) {
  $total = 0
  $latest = ""
  $page = 1
  $perPage = 100
  do {
    $encBranch = [System.Web.HttpUtility]::UrlEncode($branch)
    $chunk = gh api "/repos/$org/$repo/commits?sha=$encBranch&page=$page&per_page=$perPage" | ConvertFrom-Json
    if ($page -eq 1 -and $chunk.Count -gt 0) { $latest = $chunk[0].sha }
    $total += $chunk.Count
    $page++
  } while ($chunk.Count -eq $perPage)
  return [pscustomobject]@{ Count = $total; Latest = $latest }
}

function Validate-Migration {
  param(
    [string]$bbsProjectKey,
    [string]$bbsRepoSlug,
    [string]$bbsRepoUrl,
    [string]$githubOrg,
    [string]$githubRepo
  )

  Write-Output "[$(Get-Date)] Validating migration: $githubOrg/$githubRepo  (BBS: $bbsProjectKey/$bbsRepoSlug)" |
    Tee-Object -FilePath $LOG_FILE -Append

  # GitHub repo info snapshot
  gh repo view "$githubOrg/$githubRepo" --json createdAt,diskUsage,defaultBranchRef,isPrivate |
    Out-File -FilePath "validation-$githubRepo.json"

  $headers = Get-BbsHeaders
  $baseUrl = Compute-BbsBaseUrl $bbsRepoUrl

  # Optional sanity check: ensure CSV URL host matches provided base
  $fromCsv = ($bbsRepoUrl -replace '(?i)/projects/.*$','').TrimEnd('/')
  if ($BbsBaseUrl -and ($fromCsv -ne $BbsBaseUrl.TrimEnd('/'))) {
    throw "CSV URL host '$fromCsv' differs from BbsBaseUrl '$BbsBaseUrl' for repo '$githubRepo'."
  }

  # Branches
  $ghBranches  = Get-GhBranches  -org $githubOrg -repo $githubRepo
  $bbsBranches = Get-BbsBranches -baseUrl $baseUrl -projectKey $bbsProjectKey -repoSlug $bbsRepoSlug -headers $headers

  $ghBranchCount  = $ghBranches.Count
  $bbsBranchCount = $bbsBranches.Count
  $branchCountStatus = if ($ghBranchCount -eq $bbsBranchCount) { "✅ Matching" } else { "❌ Not Matching" }

  Write-Output "[$(Get-Date)] Branch Count: BBS=$bbsBranchCount  GitHub=$ghBranchCount  $branchCountStatus" |
    Tee-Object -FilePath $LOG_FILE -Append

  $missingInGH  = $bbsBranches | Where-Object { $_ -notin $ghBranches }
  $missingInBBS = $ghBranches  | Where-Object { $_ -notin $bbsBranches }

  if ($missingInGH.Count -gt 0) {
    Write-Output "[$(Get-Date)] Branches missing in GitHub: $($missingInGH -join ', ')" |
      Tee-Object -FilePath $LOG_FILE -Append
  }
  if ($missingInBBS.Count -gt 0) {
    Write-Output "[$(Get-Date)] Branches missing in Bitbucket: $($missingInBBS -join ', ')" |
      Tee-Object -FilePath $LOG_FILE -Append
  }

  # Commits for common branches
  foreach ($branch in ($ghBranches | Where-Object { $_ -in $bbsBranches })) {
    $ghInfo  = Get-GhCommitsInfo  -org $githubOrg -repo $githubRepo -branch $branch
    $bbsInfo = Get-BbsCommitsInfo -baseUrl $baseUrl -projectKey $bbsProjectKey -repoSlug $bbsRepoSlug -branch $branch -headers $headers

    $countMatch = ($ghInfo.Count -eq $bbsInfo.Count)
    $shaMatch   = ($ghInfo.Latest -eq $bbsInfo.Latest)

    $countStatus = if ($countMatch) { "✅ Matching" } else { "❌ Not Matching" }
    $shaStatus   = if ($shaMatch)   { "✅ Matching" } else { "❌ Not Matching" }

    Write-Output "[$(Get-Date)] Branch '$branch': BBS Commits=$($bbsInfo.Count)  GitHub Commits=$($ghInfo.Count)  $countStatus" |
      Tee-Object -FilePath $LOG_FILE -Append
    Write-Output "[$(Get-Date)] Branch '$branch': BBS SHA=$($bbsInfo.Latest)  GitHub SHA=$($ghInfo.Latest)  $shaStatus" |
      Tee-Object -FilePath $LOG_FILE -Append
  }

  Write-Output "[$(Get-Date)] Validation complete for $githubOrg/$githubRepo" |
    Tee-Object -FilePath $LOG_FILE -Append
}

function Validate-FromCSV {
  param([string]$csvPath)

  if (-not (Test-Path $csvPath)) {
    Write-Output "[$(Get-Date)] ERROR: CSV file not found: $csvPath" |
      Tee-Object -FilePath $LOG_FILE -Append
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
    $bbsUrl        = $repo.url
    $ghOrg         = $repo.github_org
    $ghRepo        = $repo.github_repo

    Write-Output "[$(Get-Date)] Processing: BBS '$bbsProjectKey/$($repo.repo)' @ $($repo.url)  -->  GH '$ghOrg/$ghRepo'" |
      Tee-Object -FilePath $LOG_FILE -Append

    Validate-Migration -bbsProjectKey $bbsProjectKey `
                       -bbsRepoSlug   $bbsRepoSlug   `
                       -bbsRepoUrl    $bbsUrl        `
                       -githubOrg     $ghOrg         `
                       -githubRepo    $ghRepo
  }

  Write-Output "[$(Get-Date)] All validations from CSV completed" |
    Tee-Object -FilePath $LOG_FILE -Append
}

# Entrypoint
if (-not $CsvPath)    { throw "CsvPath is required" }
if (-not $BbsBaseUrl) { throw "BbsBaseUrl is required" }
Validate-FromCSV -csvPath $CsvPath
