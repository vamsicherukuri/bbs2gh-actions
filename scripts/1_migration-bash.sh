#!/usr/bin/env bash
# BBS -> GitHub parallel migration runner (standalone Bash)
# - Concurrency (1..5)
# - Per-repo logs + real-time console (INFO/WARNING + final SUCCESS/FAILED)
# - Status bar + continuous CSV writes
# - SSH key resolution (raw PEM or path)
# - Ctrl-C safe
#
# Env:
#   BBS_SERVER_URL          -> e.g., http://15.206.185.229:7990/
#   GH_PAT or GH_TOKEN      -> GitHub token
#   BBS_USERNAME/BBS_PASSWORD (optional; gh bbs2gh reads env)
#   SSH_USER                -> OS user on Bitbucket host (e.g., ubuntu)
#   SSH_PRIVATE_KEY_PATH    -> absolute path to PEM (preferred)
#   SSH_PRIVATE_KEY         -> raw PEM content (alternative)
#   BBS_SSH_SERVER/BBS_SSH_PORT -> optional SSH host/port override
#
# CSV header required:
#   project-key,project-name,repo,github_org,github_repo,gh_repo_visibility

set -u
set -o pipefail

# ---------- Parameters (CLI) ----------
MAX_CONCURRENT="${1:-3}"
CSV_PATH="${2:-repos.csv}"
SSH_USER_INPUT="${3:-${SSH_USER:-}}"
SSH_PRIVATE_KEY_INPUT="${4:-${SSH_PRIVATE_KEY:-}}"
SSH_PRIVATE_KEY_PATH_INPUT="${5:-${SSH_PRIVATE_KEY_PATH:-}}"
OUTPUT_PATH="${6:-}"

# ---------- Guards ----------
if ! [[ "${MAX_CONCURRENT}" =~ ^[0-9]+$ ]]; then
  echo -e "\e[31m[ERROR]\e[0m MaxConcurrent must be an integer (got: ${MAX_CONCURRENT})" >&2; exit 1
fi
if (( MAX_CONCURRENT < 1 )); then
  echo -e "\e[31m[ERROR]\e[0m MaxConcurrent must be at least 1." >&2; exit 1
fi
if (( MAX_CONCURRENT > 5 )); then
  echo -e "\e[31m[ERROR]\e[0m Maximum concurrent migrations (${MAX_CONCURRENT}) exceeds 5." >&2; exit 1
fi

# ---------- Globals ----------
TS="$(date +%Y%m%d-%H%M%S)"
OUTPUT_CSV_PATH="${OUTPUT_PATH:-repo_migration_output-${TS}.csv}"
LOG_DIR="./"

# ---------- Helpers ----------
error() { printf "\e[31m[ERROR]\e[0m %s\n" "$*" >&2; }
warn()  { printf "\e[33m[WARN]\e[0m %s\n" "$*"; }
info()  { printf "\e[36m[INFO]\e[0m %s\n" "$*"; }
require_cmd() { command -v "$1" >/dev/null 2>&1 || { error "Required command not found: $1"; exit 1; }; }
trim() { echo "$1" | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'; }

# Tag prefix stream (portable; no awk fflush)
prefix_stream() {
  local tag="$1"
  sed -u -e "s/^/[${tag}] /"
}

# Use stdbuf if available for line-buffering; otherwise fallback
if command -v stdbuf >/dev/null 2>&1; then
  STDBUF_PREFIX=(stdbuf -oL -eL)
else
  STDBUF_PREFIX=()
fi

# ---------- Dependency checks ----------
require_cmd gh
require_cmd ssh

# ---------- Env checks ----------
BBS_SERVER_URL="${BBS_SERVER_URL:-}"
if [[ -z "${BBS_SERVER_URL}" ]]; then error "BBS_SERVER_URL is not set."; exit 1; fi
BBS_SERVER_URL="${BBS_SERVER_URL%/}"  # normalize trailing slash

GH_TOKEN_EFFECTIVE="${GH_TOKEN:-${GH_PAT:-}}"
if [[ -z "${GH_TOKEN_EFFECTIVE}" ]]; then warn "GH_TOKEN/GH_PAT not found in env. 'gh bbs2gh' may fail if token is required."; fi

# ---------- CSV header & validation ----------
if [[ ! -f "${CSV_PATH}" ]]; then error "CSV file not found: ${CSV_PATH}"; exit 1; fi
IFS= read -r HEADER_LINE < "${CSV_PATH}" || { error "CSV is empty: ${CSV_PATH}"; exit 1; }
[[ -z "${HEADER_LINE}" ]] && { error "CSV is empty: ${CSV_PATH}"; exit 1; }

declare -a HEADER=()
IFS=',' read -r -a HEADER <<< "${HEADER_LINE}"
for i in "${!HEADER[@]}"; do HEADER[$i]="$(trim "${HEADER[$i]}")"; done

declare -A COLIDX=()
for i in "${!HEADER[@]}"; do COLIDX["${HEADER[$i]}"]="$i"; done

declare -a REQUIRED_COLUMNS=('project-key' 'project-name' 'repo' 'github_org' 'github_repo' 'gh_repo_visibility')
declare -a MISSING=()
for col in "${REQUIRED_COLUMNS[@]}"; do [[ -z "${COLIDX[$col]:-}" ]] && MISSING+=("$col"); done
if [[ "${#MISSING[@]}" -gt 0 ]]; then error "CSV missing required columns: ${MISSING[*]}"; exit 1; fi

# ---------- Data arrays ----------
declare -a project_key project_name repo_slug github_org github_repo gh_vis
declare -a migration_status log_file
TOTAL=0

{
  read -r _header_line
  while IFS= read -r LINE; do
    [[ -z "${LINE}" ]] && continue
    IFS=',' read -r -a FIELDS <<< "${LINE}"
    if [[ "${#FIELDS[@]}" -lt "${#HEADER[@]}" ]]; then
      for ((k="${#FIELDS[@]}"; k<"${#HEADER[@]}"; k++)); do FIELDS[k]=""; done
    fi
    pk="$(trim "${FIELDS[${COLIDX["project-key"]}]}")"
    pn="$(trim "${FIELDS[${COLIDX["project-name"]}]}")"
    rs="$(trim "${FIELDS[${COLIDX["repo"]}]}")"
    go="$(trim "${FIELDS[${COLIDX["github_org"]}]}")"
    gr="$(trim "${FIELDS[${COLIDX["github_repo"]}]}")"
    gv="$(trim "${FIELDS[${COLIDX["gh_repo_visibility"]}]}")"
    [[ -z "${pk}" || -z "${rs}" || -z "${gr}" ]] && continue

    project_key[${TOTAL}]="${pk}"
    project_name[${TOTAL}]="${pn}"
    repo_slug[${TOTAL}]="${rs}"
    github_org[${TOTAL}]="${go}"
    github_repo[${TOTAL}]="${gr}"
    gh_vis[${TOTAL}]="${gv}"
    migration_status[${TOTAL}]="Pending"
    log_file[${TOTAL}]=""
    (( TOTAL++ ))
  done
} < "${CSV_PATH}"

if (( TOTAL == 0 )); then error "CSV has no valid rows."; exit 1; fi

# ---------- Output CSV ----------
write_output_csv() {
  {
    printf 'project-key,project-name,repo,github_org,github_repo,gh_repo_visibility,Migration_Status,Log_File\n'
    for ((i=0;i<TOTAL;i++)); do
      printf '%s,%s,%s,%s,%s,%s,%s,%s\n' \
        "${project_key[$i]}" \
        "${project_name[$i]}" \
        "${repo_slug[$i]}" \
        "${github_org[$i]}" \
        "${github_repo[$i]}" \
        "${gh_vis[$i]}" \
        "${migration_status[$i]}" \
        "${log_file[$i]}"
    done
  } > "${OUTPUT_CSV_PATH}"
}

write_output_csv
info "Starting migration with ${MAX_CONCURRENT} concurrent jobs..."
info "Processing ${TOTAL} repositories from: ${CSV_PATH}"
info "Initialized migration status output: ${OUTPUT_CSV_PATH}"

# ---------- SSH private key resolution ----------
resolve_private_key_path() {
  local key_input="$1" path_input="$2" outfile

  # Case 1: raw PEM provided via arg
  if [[ -n "${key_input}" ]] && grep -q -- '-----BEGIN .*PRIVATE KEY-----' <<< "${key_input}"; then
    outfile="$(mktemp -t bbs2gh_sshkey_XXXXXX.pem)"
    printf '%s' "${key_input}" > "${outfile}"
    chmod 600 "${outfile}"
    echo "${outfile}"
    return 0
  fi

  # Case 2: explicit path arg
  if [[ -n "${path_input}" ]]; then
    echo "${path_input}"
    return 0
  fi

  # Case 3: SSH_PRIVATE_KEY is a file path
  if [[ -n "${SSH_PRIVATE_KEY:-}" ]] && [[ -f "${SSH_PRIVATE_KEY}" ]]; then
    echo "${SSH_PRIVATE_KEY}"
    return 0
  fi

  # Case 4: raw PEM in env SSH_PRIVATE_KEY
  if [[ -n "${SSH_PRIVATE_KEY:-}" ]] && grep -q -- '-----BEGIN .*PRIVATE KEY-----' <<< "${SSH_PRIVATE_KEY}"; then
    outfile="$(mktemp -t bbs2gh_sshkey_XXXXXX.pem)"
    printf '%s' "${SSH_PRIVATE_KEY}" > "${outfile}"
    chmod 600 "${outfile}"
    echo "${outfile}"
    return 0
  fi

  # Case 5: SSH_PRIVATE_KEY_PATH in env
  if [[ -n "${SSH_PRIVATE_KEY_PATH:-}" ]]; then
    echo "${SSH_PRIVATE_KEY_PATH}"
    return 0
  fi

  echo ""; return 0
}

RESOLVED_SSH_KEY_PATH="$(resolve_private_key_path "${SSH_PRIVATE_KEY_INPUT}" "${SSH_PRIVATE_KEY_PATH_INPUT}")"
if [[ -z "${RESOLVED_SSH_KEY_PATH}" || ! -f "${RESOLVED_SSH_KEY_PATH}" ]]; then
  warn "SSH private key path is missing/invalid. Archive download via SSH may fail."
fi

SSH_USER_EFFECTIVE="${SSH_USER_INPUT:-${SSH_USER:-}}"
[[ -z "${SSH_USER_EFFECTIVE}" ]] && warn "SSH user (SSH_USER) is not set; archive download may fail."

# ---------- Optional SSH preflight ----------
preflight_ssh() {
  local host="${BBS_SSH_SERVER:-$(echo "${BBS_SERVER_URL}" | sed 's~https\?://~~; s~/.*~~')}"
  local port="${BBS_SSH_PORT:-22}"
  local user="${SSH_USER_EFFECTIVE}"
  if [[ -z "${user}" || -z "${RESOLVED_SSH_KEY_PATH}" || ! -f "${RESOLVED_SSH_KEY_PATH}" ]]; then
    warn "SSH preflight skipped (missing user or key)."; return 0
  fi
  info "SSH preflight: user=${user} host=${host} port=${port}"
  if ssh -o BatchMode=yes -o StrictHostKeyChecking=no -i "${RESOLVED_SSH_KEY_PATH}" -p "${port}" "${user}@${host}" "echo OK" >/dev/null 2>&1; then
    info "SSH preflight OK"; return 0
  else
    error "SSH preflight failed. Verify authorized_keys, permissions, and firewall for ${host}:${port}."; return 1
  fi
}
# Uncomment to enforce:
# preflight_ssh || exit 1

# ---------- Migration command (streams only INFO/WARNING to console) ----------
migrate_one() {
  local idx="$1" log="$2"
  local pk rs go gr gv
  pk="${project_key[$idx]}"; rs="${repo_slug[$idx]}"; go="${github_org[$idx]}"; gr="${github_repo[$idx]}"; gv="${gh_vis[$idx]}"

  # Announce start to log + console (console filtered)
  {
    printf "[%s] [START] Migration: %s/%s -> %s/%s (visibility: %s)\n" "$(date)" "${pk}" "${rs}" "${go}" "${gr}" "${gv}"
    printf "[%s] [DEBUG] Using BBS_SERVER_URL: %s\n" "$(date)" "${BBS_SERVER_URL}"
    printf "[%s] [DEBUG] SSH user: %s | SSH key: %s\n" "$(date)" "${SSH_USER_EFFECTIVE:-<empty>}" "${RESOLVED_SSH_KEY_PATH:-<empty>}"
    printf "[%s] [INFO] VERBOSE: true\n" "$(date)"
  } | tee -a "${log}" \
    | grep -E -- '\[(INFO|WARNING)\]' \
    | prefix_stream "${gr}"

  GH_SSH_SERVER_ARGS=()
  [[ -n "${BBS_SSH_SERVER:-}" ]] && GH_SSH_SERVER_ARGS+=( --ssh-server "${BBS_SSH_SERVER}" )
  [[ -n "${BBS_SSH_PORT:-}"   ]] && GH_SSH_SERVER_ARGS+=( --ssh-port "${BBS_SSH_PORT}" )

  # Stream gh CLI output live: full to log, filtered to console
  "${STDBUF_PREFIX[@]}" gh bbs2gh migrate-repo \
    --bbs-server-url "${BBS_SERVER_URL}" \
    --bbs-project "${pk}" \
    --bbs-repo "${rs}" \
    --github-org "${go}" \
    --github-repo "${gr}" \
    --use-github-storage \
    --verbose \
    ${SSH_USER_EFFECTIVE:+--ssh-user "${SSH_USER_EFFECTIVE}"} \
    ${RESOLVED_SSH_KEY_PATH:+--ssh-private-key "${RESOLVED_SSH_KEY_PATH}"} \
    ${GH_SSH_SERVER_ARGS[@]} \
    --target-api-url "https://api.github.com" \
    --target-repo-visibility "${gv}" \
    2>&1 | tee -a "${log}" \
          | grep -E -- '\[(INFO|WARNING)\]' \
          | prefix_stream "${gr}"

  local exit=$?
  if (( exit == 0 )); then
    printf "[%s] [SUCCESS] Migration: %s/%s -> %s/%s\n" "$(date)" "${pk}" "${rs}" "${go}" "${gr}" \
      | tee -a "${log}" \
      | grep -E -- '\[(SUCCESS|INFO|WARNING)\]' \
      | prefix_stream "${gr}"
  else
    printf "[%s] [FAILED]  Migration: %s/%s -> %s/%s (exit: %d)\n" "$(date)" "${pk}" "${rs}" "${go}" "${gr}" "${exit}" \
      | tee -a "${log}" \
      | grep -E -- '\[(FAILED|INFO|WARNING)\]' \
      | prefix_stream "${gr}"
  fi
  return "${exit}"
}

# ---------- Concurrency controller ----------
declare -a RUN_PIDS=()
declare -A PID_TO_INDEX=()

MIGRATED_COUNT=0
FAILED_COUNT=0
status_line_width=0

show_status_bar() {
  local q=$(( TOTAL - MIGRATED_COUNT - FAILED_COUNT - ${#RUN_PIDS[@]} ))
  local status="QUEUE: ${q} | IN PROGRESS: ${#RUN_PIDS[@]} | MIGRATED: ${MIGRATED_COUNT} | MIGRATION FAILED: ${FAILED_COUNT}"
  (( ${#status} > status_line_width )) && status_line_width=${#status}
  printf "\r\e[36m%s\e[0m" "$(printf "%-${status_line_width}s" "${status}")"
}

INTERRUPTED=false
cleanup() {
  INTERRUPTED=true
  for pid in "${RUN_PIDS[@]}"; do kill "$pid" >/dev/null 2>&1 || true; done
  printf "\n"
}
trap cleanup INT TERM

next_idx=0
show_status_bar

while (( next_idx < TOTAL || ${#RUN_PIDS[@]} > 0 )); do
  # Start jobs
  while (( ${#RUN_PIDS[@]} < MAX_CONCURRENT && next_idx < TOTAL )); do
    lf="${LOG_DIR}/migration-${github_repo[$next_idx]}-$(date +%Y%m%d-%H%M%S)-${next_idx}.txt"
    log_file[$next_idx]="${lf}"
    write_output_csv

    ( migrate_one "${next_idx}" "${lf}" ) &
    pid=$!
    PID_TO_INDEX["$pid"]="${next_idx}"
    RUN_PIDS+=( "$pid" )

    show_status_bar
    (( next_idx++ ))
  done

  # Wait for earliest PID and update state
  if [[ "${#RUN_PIDS[@]}" -gt 0 ]]; then
    pid="${RUN_PIDS[0]}"
    if wait "$pid"; then exit_code=0; else exit_code=$?; fi

    idx="${PID_TO_INDEX[$pid]:-}"       # guard against Ctrl-C missing map
    RUN_PIDS=( "${RUN_PIDS[@]:1}" )
    [[ -n "${idx}" ]] || { write_output_csv; show_status_bar; continue; }

    if (( exit_code == 0 )); then
      migration_status[$idx]="Success"; (( MIGRATED_COUNT++ ))
    else
      migration_status[$idx]="Failure"; (( FAILED_COUNT++ ))
    fi

    unset 'PID_TO_INDEX[$pid]'
    write_output_csv
    show_status_bar
  fi

  [[ "${INTERRUPTED}" == "true" ]] && break
done

printf "\n"
info "All migrations completed."
printf "\e[32m[SUMMARY] Total: %d | Migrated: %d | Failed: %d\e[0m\n" "${TOTAL}" "${MIGRATED_COUNT}" "${FAILED_COUNT}"
info "Wrote migration results with Migration_Status column: ${OUTPUT_CSV_PATH}"
(( FAILED_COUNT > 0 )) && warn "Migration completed with ${FAILED_COUNT} failures"
