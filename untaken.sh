#!/usr/bin/env bash

# untaken - Pro TikTok username availability checker (enhanced Bash CLI)
# Original author: Haitham Aouati
# Major upgrade: concurrency, resume/cache, richer exports, stricter networking controls

set -uo pipefail

APP_NAME="untaken"
VERSION="4.0.0"

# ---------------- Defaults ----------------
NO_COLOR=0
QUIET=0
NO_BANNER=0
APPEND=0
VALIDATE=1
STRICT_MODE=0
SUMMARY_ONLY=0
KEEP_DUPLICATES=0
DRY_RUN=0
RESUME=0
SHUFFLE_INPUT=0
ROTATE_USER_AGENT=0
INSECURE_TLS=0
USE_STDIN=0
PIPE_STDIN=0
INTERRUPTED=0

TIMEOUT=15
CONNECT_TIMEOUT=8
RETRIES=2
DELAY=0
WORKERS=1
CACHE_TTL=0           # seconds; 0 means always trust cache if present
MAX_BODY_KB=512       # clamp parsed body size

PROFILE=""
PROXY=""
OUTPUT_DIR=""
CSV_PATH=""
JSON_PATH=""
NDJSON_PATH=""
SUMMARY_JSON_PATH=""
SAVE_BODIES_DIR=""
CACHE_DIR=""
CONFIG_FILE=""
PRINT_FORMAT="pretty"   # pretty | tsv | jsonl

USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"
UA_POOL=(
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"
  "Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/121.0 Safari/537.36"
  "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/17.2 Safari/605.1.15"
  "Mozilla/5.0 (Windows NT 10.0; Win64; x64; rv:123.0) Gecko/20100101 Firefox/123.0"
)

# ---------------- Inputs ----------------
TARGETS=()      # legacy -u can be username OR file
INPUT_FILES=()

# ---------------- Runtime state ----------------
RUN_TS_FILE=$(date '+%Y%m%d_%H%M%S')
RUN_TS_HUMAN=$(date '+%Y-%m-%d %H:%M:%S')
START_TS=$(date +%s)
TOTAL=0
PROCESSED=0
COUNT_TAKEN=0
COUNT_UNTAKEN=0
COUNT_UNKNOWN=0
COUNT_INVALID=0
COUNT_CACHE_HITS=0
COUNT_RESUMED_SKIPS=0
COUNT_DRYRUN=0

TAKEN_FILE=""
UNTAKEN_FILE=""
UNKNOWN_FILE=""
INVALID_FILE=""
RESULTS_CSV=""
SUMMARY_FILE=""
SUMMARY_JSON_FILE=""
RESULTS_NDJSON=""

TMP_ALL_RESULTS=""
TMP_USERS_RAW=""
TMP_USERS_FINAL=""
TMP_USERS_WORKLIST=""
TMP_RESUME_SEEN=""
JOB_DIR=""

# ---------------- Colors ----------------
init_colors() {
  if [[ "$NO_COLOR" -eq 1 || ! -t 1 ]]; then
    nc=""; green=""; red=""; yellow=""; blue=""; cyan=""; bold=""; underline=""
  else
    nc="\e[0m"
    green="\e[1;32m"
    red="\e[1;31m"
    yellow="\e[1;33m"
    blue="\e[1;34m"
    cyan="\e[1;36m"
    bold="\e[1m"
    underline="\e[4m"
  fi
}

# ---------------- Logging ----------------
say() { [[ "$QUIET" -eq 1 ]] || printf '%b\n' "$*"; }
warn() { printf '%b\n' "${yellow}Warning:${nc} $*" >&2; }
err() { printf '%b\n' "${red}Error:${nc} $*" >&2; }

print_banner() {
  [[ "$QUIET" -eq 1 || "$NO_BANNER" -eq 1 ]] && return 0
  clear 2>/dev/null || true
  echo -e "${bold}"
  echo "         _       _           "
  echo " _ _ ___| |_ ___| |_ ___ ___ "
  echo "| | |   |  _| .'| '_| -_|   |"
  echo "|___|_|_|_| |__,|_,_|___|_|_|"
  echo -e "${nc}"
  echo -e " ${cyan}${bold}${APP_NAME}${nc} v${VERSION}"
  echo -e " Original author: Haitham Aouati"
  echo -e " Pro CLI upgrade (parallel/resume/cache)\n"
}

usage() {
  cat <<'EOF'
Usage:
  untaken -u <username>
  untaken -u <file.txt>                     # legacy behavior (auto-detect file)
  untaken -f usernames.txt
  cat usernames.txt | untaken --stdin

Input options:
  -u, --username <value>                    Username OR file path (backward compatible)
  -f, --file <file>                         File with usernames (one per line)
      --stdin                               Read usernames from STDIN
      --keep-duplicates                     Do not de-duplicate usernames (default: dedupe)
      --no-validate                         Skip username validation
      --shuffle                             Shuffle input order before checking
      --resume                              Skip usernames already found in existing outputs (best with --append + same output dir)

Performance / behavior:
      --workers <n>                         Parallel workers (default: 1)
      --profile <fast|balanced|conservative>
      --dry-run                             Validate/normalize/export without network requests

Output options:
  -o, --output-dir <dir>                    Output dir (default: untaken_results_<timestamp>)
      --csv <file>                          Export all results to CSV (default: <output-dir>/results.csv)
      --json <file>                         Export all results to JSON array
      --ndjson <file>                       Export newline-delimited JSON
      --summary-json <file>                 Write machine-readable run summary JSON
      --save-bodies-dir <dir>               Save response bodies per username (debugging)
      --append                              Append to text/csv/ndjson outputs instead of truncating
      --summary-only                        Show final summary only (no per-item output)
      --print-format <pretty|tsv|jsonl>     Terminal output format (default: pretty)

Network / detection:
      --timeout <sec>                       Curl total timeout per request (default: 15)
      --connect-timeout <sec>               Curl connect timeout (default: 8)
      --retries <n>                         Retries on transient errors (default: 2)
      --delay <sec>                         Delay between checks (per job, default: 0)
      --user-agent <ua>                     Custom User-Agent
      --rotate-user-agent                   Rotate from built-in UA pool per request
      --proxy <url>                         Curl proxy (e.g. http://127.0.0.1:8080)
      --insecure                            Skip TLS cert verification (debug only)
      --strict                              Classify as UNTAKEN only on explicit “not found” clues
      --max-body-kb <n>                     Clamp response parsing size (default: 512)

Cache:
      --cache-dir <dir>                     Read/write per-username cache entries
      --cache-ttl <sec>                     Reuse cached entries newer than TTL (0 = always if present)

UI / general:
  -q, --quiet                               Quiet mode
      --no-banner                           Disable banner
      --no-color                            Disable ANSI colors
      --config <file>                       KEY=VALUE config file (optional)
  -V, --version                             Print version
  -h, --help                                Show help

Examples:
  untaken -u mybrandname
  untaken -f usernames.txt --workers 8 --strict --delay 0.2
  untaken -f names.txt --resume --append -o runs/daily
  untaken -f names.txt --cache-dir .cache/untaken --cache-ttl 86400
  untaken -f names.txt --ndjson out/results.ndjson --summary-json out/summary.json
EOF
}

show_version() { echo "${APP_NAME} ${VERSION}"; }

check_dependencies() {
  local missing=0
  for cmd in curl grep sed awk wc date mktemp basename dirname; do
    if ! command -v "$cmd" >/dev/null 2>&1; then
      err "$cmd is required but not installed."
      missing=1
    fi
  done
  (( missing == 0 )) || exit 1
}

cleanup() {
  [[ -n "$TMP_ALL_RESULTS" && -f "$TMP_ALL_RESULTS" ]] && rm -f "$TMP_ALL_RESULTS"
  [[ -n "$TMP_USERS_RAW" && -f "$TMP_USERS_RAW" ]] && rm -f "$TMP_USERS_RAW"
  [[ -n "$TMP_USERS_FINAL" && -f "$TMP_USERS_FINAL" ]] && rm -f "$TMP_USERS_FINAL"
  [[ -n "$TMP_USERS_WORKLIST" && -f "$TMP_USERS_WORKLIST" ]] && rm -f "$TMP_USERS_WORKLIST"
  [[ -n "$TMP_RESUME_SEEN" && -f "$TMP_RESUME_SEEN" ]] && rm -f "$TMP_RESUME_SEEN"
  [[ -n "$JOB_DIR" && -d "$JOB_DIR" ]] && rm -rf "$JOB_DIR"
}
trap cleanup EXIT
trap 'INTERRUPTED=1; warn "Interrupted. Finishing active jobs and writing summary..."' INT TERM

trim() {
  local s="$1"
  s="${s//$'\r'/}"
  s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  printf '%s' "$s"
}

normalize_username() {
  local u
  u=$(trim "$1")
  [[ -z "$u" ]] && return 1
  [[ "$u" =~ ^# ]] && return 1
  u="${u%%[[:space:]]*}"
  u="${u#@}"
  u="${u#https://www.tiktok.com/@}"
  u="${u#http://www.tiktok.com/@}"
  u="${u#https://tiktok.com/@}"
  u="${u#http://tiktok.com/@}"
  u="${u#www.tiktok.com/@}"
  u="${u#tiktok.com/@}"
  u="${u%%\?*}"
  u="${u%%/*}"
  u=$(trim "$u")
  [[ -z "$u" ]] && return 1
  printf '%s' "$u"
  return 0
}

is_valid_username() {
  local u="$1"
  [[ "$u" =~ ^[A-Za-z0-9._]{2,24}$ ]]
}

csv_escape() {
  local s="$1"
  s=${s//\"/\"\"}
  printf '"%s"' "$s"
}

json_escape() {
  local s="$1"
  s=${s//\\/\\\\}
  s=${s//\"/\\\"}
  s=${s//$'\n'/\\n}
  s=${s//$'\r'/\\r}
  s=${s//$'\t'/\\t}
  printf '%s' "$s"
}

parse_bool() {
  case "${1,,}" in
    1|true|yes|on) echo 1 ;;
    0|false|no|off) echo 0 ;;
    *) return 1 ;;
  esac
}

apply_profile() {
  case "$1" in
    fast)
      WORKERS=12; TIMEOUT=10; CONNECT_TIMEOUT=5; RETRIES=1; DELAY=0; STRICT_MODE=0 ;;
    balanced)
      WORKERS=4; TIMEOUT=15; CONNECT_TIMEOUT=8; RETRIES=2; DELAY=0; STRICT_MODE=0 ;;
    conservative)
      WORKERS=2; TIMEOUT=25; CONNECT_TIMEOUT=10; RETRIES=3; DELAY=0.7; STRICT_MODE=1 ;;
    *)
      err "Invalid --profile value: $1 (use fast|balanced|conservative)"
      exit 1
      ;;
  esac
}

load_config() {
  local file="$1" line key value parsed
  [[ -f "$file" ]] || { err "Config file not found: $file"; exit 1; }
  while IFS= read -r line || [[ -n "$line" ]]; do
    line=$(trim "$line")
    [[ -z "$line" || "$line" =~ ^# ]] && continue
    key="${line%%=*}"
    value="${line#*=}"
    key=$(trim "$key")
    value=$(trim "$value")
    case "$key" in
      timeout) TIMEOUT="$value" ;;
      connect_timeout) CONNECT_TIMEOUT="$value" ;;
      retries) RETRIES="$value" ;;
      delay) DELAY="$value" ;;
      workers) WORKERS="$value" ;;
      strict_mode) parsed=$(parse_bool "$value") || { err "Invalid boolean in config: $key=$value"; exit 1; }; STRICT_MODE="$parsed" ;;
      validate) parsed=$(parse_bool "$value") || { err "Invalid boolean in config: $key=$value"; exit 1; }; VALIDATE="$parsed" ;;
      rotate_user_agent) parsed=$(parse_bool "$value") || { err "Invalid boolean in config: $key=$value"; exit 1; }; ROTATE_USER_AGENT="$parsed" ;;
      proxy) PROXY="$value" ;;
      print_format) PRINT_FORMAT="$value" ;;
      cache_dir) CACHE_DIR="$value" ;;
      cache_ttl) CACHE_TTL="$value" ;;
      profile) apply_profile "$value"; PROFILE="$value" ;;
      user_agent) USER_AGENT="$value" ;;
      *) warn "Unknown config key ignored: $key" ;;
    esac
  done < "$file"
}

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --config)
        [[ $# -lt 2 ]] && { err "Missing file for $1"; exit 1; }
        CONFIG_FILE="$2"; load_config "$CONFIG_FILE"; shift 2 ;;
      --profile)
        [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }
        PROFILE="$2"; apply_profile "$2"; shift 2 ;;
      -u|--username)
        [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }
        TARGETS+=("$2"); shift 2 ;;
      -f|--file)
        [[ $# -lt 2 ]] && { err "Missing file for $1"; exit 1; }
        INPUT_FILES+=("$2"); shift 2 ;;
      --stdin) USE_STDIN=1; shift ;;
      --keep-duplicates) KEEP_DUPLICATES=1; shift ;;
      --no-validate) VALIDATE=0; shift ;;
      --shuffle) SHUFFLE_INPUT=1; shift ;;
      --resume) RESUME=1; shift ;;
      --dry-run) DRY_RUN=1; shift ;;
      --workers) [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }; WORKERS="$2"; shift 2 ;;
      -o|--output-dir) [[ $# -lt 2 ]] && { err "Missing directory for $1"; exit 1; }; OUTPUT_DIR="$2"; shift 2 ;;
      --csv) [[ $# -lt 2 ]] && { err "Missing file path for $1"; exit 1; }; CSV_PATH="$2"; shift 2 ;;
      --json) [[ $# -lt 2 ]] && { err "Missing file path for $1"; exit 1; }; JSON_PATH="$2"; shift 2 ;;
      --ndjson) [[ $# -lt 2 ]] && { err "Missing file path for $1"; exit 1; }; NDJSON_PATH="$2"; shift 2 ;;
      --summary-json) [[ $# -lt 2 ]] && { err "Missing file path for $1"; exit 1; }; SUMMARY_JSON_PATH="$2"; shift 2 ;;
      --save-bodies-dir) [[ $# -lt 2 ]] && { err "Missing dir for $1"; exit 1; }; SAVE_BODIES_DIR="$2"; shift 2 ;;
      --append) APPEND=1; shift ;;
      --summary-only) SUMMARY_ONLY=1; shift ;;
      --print-format) [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }; PRINT_FORMAT="$2"; shift 2 ;;
      --timeout) [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }; TIMEOUT="$2"; shift 2 ;;
      --connect-timeout) [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }; CONNECT_TIMEOUT="$2"; shift 2 ;;
      --retries) [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }; RETRIES="$2"; shift 2 ;;
      --delay) [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }; DELAY="$2"; shift 2 ;;
      --user-agent) [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }; USER_AGENT="$2"; shift 2 ;;
      --rotate-user-agent) ROTATE_USER_AGENT=1; shift ;;
      --proxy) [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }; PROXY="$2"; shift 2 ;;
      --insecure) INSECURE_TLS=1; shift ;;
      --strict) STRICT_MODE=1; shift ;;
      --max-body-kb) [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }; MAX_BODY_KB="$2"; shift 2 ;;
      --cache-dir) [[ $# -lt 2 ]] && { err "Missing directory for $1"; exit 1; }; CACHE_DIR="$2"; shift 2 ;;
      --cache-ttl) [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }; CACHE_TTL="$2"; shift 2 ;;
      -q|--quiet) QUIET=1; shift ;;
      --no-banner) NO_BANNER=1; shift ;;
      --no-color) NO_COLOR=1; shift ;;
      -V|--version) show_version; exit 0 ;;
      -h|--help) usage; exit 0 ;;
      *) err "Unknown option: $1"; usage; exit 1 ;;
    esac
  done
}

validate_numeric_flags() {
  [[ "$TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || { err "--timeout must be numeric"; exit 1; }
  [[ "$CONNECT_TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || { err "--connect-timeout must be numeric"; exit 1; }
  [[ "$RETRIES" =~ ^[0-9]+$ ]] || { err "--retries must be a non-negative integer"; exit 1; }
  [[ "$DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || { err "--delay must be numeric"; exit 1; }
  [[ "$WORKERS" =~ ^[0-9]+$ && "$WORKERS" -ge 1 ]] || { err "--workers must be an integer >= 1"; exit 1; }
  [[ "$MAX_BODY_KB" =~ ^[0-9]+$ && "$MAX_BODY_KB" -ge 1 ]] || { err "--max-body-kb must be an integer >= 1"; exit 1; }
  [[ "$CACHE_TTL" =~ ^[0-9]+$ ]] || { err "--cache-ttl must be a non-negative integer"; exit 1; }
  case "$PRINT_FORMAT" in pretty|tsv|jsonl) ;; *) err "--print-format must be pretty|tsv|jsonl"; exit 1 ;; esac
}

setup_output() {
  [[ -n "$OUTPUT_DIR" ]] || OUTPUT_DIR="untaken_results_${RUN_TS_FILE}"
  mkdir -p "$OUTPUT_DIR" || { err "Failed to create output directory: $OUTPUT_DIR"; exit 1; }

  TAKEN_FILE="$OUTPUT_DIR/taken.txt"
  UNTAKEN_FILE="$OUTPUT_DIR/untaken.txt"
  UNKNOWN_FILE="$OUTPUT_DIR/unknown.txt"
  INVALID_FILE="$OUTPUT_DIR/invalid.txt"
  SUMMARY_FILE="$OUTPUT_DIR/summary.txt"
  RESULTS_CSV="${CSV_PATH:-$OUTPUT_DIR/results.csv}"
  RESULTS_NDJSON="${NDJSON_PATH:-$OUTPUT_DIR/results.ndjson}"
  SUMMARY_JSON_FILE="${SUMMARY_JSON_PATH:-$OUTPUT_DIR/summary.json}"

  mkdir -p "$(dirname "$RESULTS_CSV")" 2>/dev/null || true
  mkdir -p "$(dirname "$RESULTS_NDJSON")" 2>/dev/null || true
  [[ -n "$JSON_PATH" ]] && mkdir -p "$(dirname "$JSON_PATH")" 2>/dev/null || true
  [[ -n "$SUMMARY_JSON_FILE" ]] && mkdir -p "$(dirname "$SUMMARY_JSON_FILE")" 2>/dev/null || true
  [[ -n "$SAVE_BODIES_DIR" ]] && mkdir -p "$SAVE_BODIES_DIR" || true
  [[ -n "$CACHE_DIR" ]] && mkdir -p "$CACHE_DIR" || true

  if [[ "$APPEND" -eq 0 ]]; then
    : > "$TAKEN_FILE"
    : > "$UNTAKEN_FILE"
    : > "$UNKNOWN_FILE"
    : > "$INVALID_FILE"
    : > "$RESULTS_CSV"
    : > "$RESULTS_NDJSON"
  else
    touch "$TAKEN_FILE" "$UNTAKEN_FILE" "$UNKNOWN_FILE" "$INVALID_FILE" "$RESULTS_CSV" "$RESULTS_NDJSON"
  fi

  [[ ! -s "$RESULTS_CSV" ]] && echo 'username,status,http_code,attempts,timestamp,reason,source' > "$RESULTS_CSV"

  TMP_ALL_RESULTS=$(mktemp)
  TMP_USERS_RAW=$(mktemp)
  TMP_USERS_FINAL=$(mktemp)
  TMP_USERS_WORKLIST=$(mktemp)
  TMP_RESUME_SEEN=$(mktemp)
  JOB_DIR=$(mktemp -d)
}

collect_targets() {
  local item line normalized

  for item in "${TARGETS[@]}"; do
    if [[ -f "$item" ]]; then
      INPUT_FILES+=("$item")
    else
      echo "$item" >> "$TMP_USERS_RAW"
    fi
  done

  for item in "${INPUT_FILES[@]}"; do
    if [[ ! -f "$item" ]]; then
      err "Input file not found: $item"
      exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      echo "$line" >> "$TMP_USERS_RAW"
    done < "$item"
  done

  if [[ ! -t 0 ]]; then PIPE_STDIN=1; fi
  if [[ "$USE_STDIN" -eq 1 || "$PIPE_STDIN" -eq 1 ]]; then
    while IFS= read -r line || [[ -n "$line" ]]; do
      echo "$line" >> "$TMP_USERS_RAW"
    done
  fi

  if [[ ! -s "$TMP_USERS_RAW" ]]; then
    err "No usernames provided. Use -u, -f, or --stdin."
    usage
    exit 1
  fi

  while IFS= read -r line || [[ -n "$line" ]]; do
    normalized=$(normalize_username "$line") || continue
    echo "$normalized"
  done < "$TMP_USERS_RAW" > "$TMP_USERS_FINAL.tmp"

  if [[ "$KEEP_DUPLICATES" -eq 0 ]]; then
    awk '!seen[$0]++' "$TMP_USERS_FINAL.tmp" > "$TMP_USERS_FINAL"
    rm -f "$TMP_USERS_FINAL.tmp"
  else
    mv "$TMP_USERS_FINAL.tmp" "$TMP_USERS_FINAL"
  fi

  if [[ "$SHUFFLE_INPUT" -eq 1 ]]; then
    if command -v shuf >/dev/null 2>&1; then
      shuf "$TMP_USERS_FINAL" > "$TMP_USERS_FINAL.shuf" && mv "$TMP_USERS_FINAL.shuf" "$TMP_USERS_FINAL"
    else
      warn "--shuffle requested but 'shuf' is unavailable; preserving input order."
    fi
  fi

  TOTAL=$(grep -cv '^[[:space:]]*$' "$TMP_USERS_FINAL" || true)
  if [[ "$TOTAL" -eq 0 ]]; then
    err "No valid input lines found after normalization."
    exit 1
  fi
}

build_resume_seen_set() {
  : > "$TMP_RESUME_SEEN"

  if [[ -f "$RESULTS_CSV" && -s "$RESULTS_CSV" ]]; then
    awk -F, 'NR>1{u=$1; gsub(/^"|"$/,"",u); if(u!="") print u}' "$RESULTS_CSV" >> "$TMP_RESUME_SEEN" || true
  fi
  if [[ -f "$RESULTS_NDJSON" && -s "$RESULTS_NDJSON" ]]; then
    sed -n 's/.*"username":"\([^"]*\)".*/\1/p' "$RESULTS_NDJSON" >> "$TMP_RESUME_SEEN" || true
  fi
  for f in "$TAKEN_FILE" "$UNTAKEN_FILE" "$UNKNOWN_FILE" "$INVALID_FILE"; do
    [[ -f "$f" ]] && cat "$f" >> "$TMP_RESUME_SEEN" || true
  done

  if [[ -s "$TMP_RESUME_SEEN" ]]; then
    awk '!seen[$0]++' "$TMP_RESUME_SEEN" > "$TMP_RESUME_SEEN.tmp" && mv "$TMP_RESUME_SEEN.tmp" "$TMP_RESUME_SEEN"
  fi
}

prepare_worklist() {
  if [[ "$RESUME" -eq 1 ]]; then
    build_resume_seen_set
    if [[ -s "$TMP_RESUME_SEEN" ]]; then
      awk 'NR==FNR {seen[$0]=1; next} !seen[$0]' "$TMP_RESUME_SEEN" "$TMP_USERS_FINAL" > "$TMP_USERS_WORKLIST"
      COUNT_RESUMED_SKIPS=$(( TOTAL - $(grep -cv '^[[:space:]]*$' "$TMP_USERS_WORKLIST" || true) ))
      (( COUNT_RESUMED_SKIPS < 0 )) && COUNT_RESUMED_SKIPS=0
    else
      cp "$TMP_USERS_FINAL" "$TMP_USERS_WORKLIST"
    fi
  else
    cp "$TMP_USERS_FINAL" "$TMP_USERS_WORKLIST"
  fi
  TOTAL=$(grep -cv '^[[:space:]]*$' "$TMP_USERS_WORKLIST" || true)
}

print_run_config() {
  [[ "$QUIET" -eq 1 ]] && return 0
  echo -e "${bold}Loaded ${TOTAL} usernames${nc}"
  [[ "$RESUME" -eq 1 && "$COUNT_RESUMED_SKIPS" -gt 0 ]] && echo -e "Resume skipped: ${yellow}${COUNT_RESUMED_SKIPS}${nc}"
  echo -e "Output directory: ${blue}${OUTPUT_DIR}${nc}"
  echo -e "CSV export: ${blue}${RESULTS_CSV}${nc}"
  echo -e "NDJSON export: ${blue}${RESULTS_NDJSON}${nc}"
  [[ -n "$JSON_PATH" ]] && echo -e "JSON export: ${blue}${JSON_PATH}${nc}"
  echo -e "Workers=${WORKERS} | Timeout=${TIMEOUT}s | ConnTimeout=${CONNECT_TIMEOUT}s | Retries=${RETRIES} | Delay=${DELAY}s"
  echo -e "Strict=${STRICT_MODE} | Validate=${VALIDATE} | Resume=${RESUME} | CacheDir=${CACHE_DIR:-none} | RotateUA=${ROTATE_USER_AGENT} | DryRun=${DRY_RUN}"
  [[ -n "$PROFILE" ]] && echo -e "Profile: ${cyan}${PROFILE}${nc}"
  echo
}

pick_user_agent() {
  if [[ "$ROTATE_USER_AGENT" -eq 1 ]]; then
    local idx=$(( RANDOM % ${#UA_POOL[@]} ))
    printf '%s' "${UA_POOL[$idx]}"
  else
    printf '%s' "$USER_AGENT"
  fi
}

cache_path_for() {
  local username="$1"
  [[ -z "$CACHE_DIR" ]] && return 1
  printf '%s/%s.cache' "$CACHE_DIR" "$username"
}

cache_lookup() {
  local username="$1" f now ts age line
  [[ -n "$CACHE_DIR" ]] || return 1
  f=$(cache_path_for "$username") || return 1
  [[ -f "$f" ]] || return 1

  line=$(tail -n 1 "$f" 2>/dev/null || true)
  [[ -n "$line" ]] || return 1
  IFS='|' read -r ts LAST_STATUS LAST_HTTP LAST_ATTEMPTS LAST_REASON <<< "$line"
  [[ -n "${ts:-}" && -n "${LAST_STATUS:-}" ]] || return 1

  now=$(date +%s)
  age=$(( now - ts ))
  if [[ "$CACHE_TTL" -gt 0 && "$age" -gt "$CACHE_TTL" ]]; then
    return 1
  fi
  LAST_SOURCE="cache"
  return 0
}

cache_store() {
  local username="$1" status="$2" http_code="$3" attempts="$4" reason="$5" f
  [[ -n "$CACHE_DIR" ]] || return 0
  f=$(cache_path_for "$username") || return 0
  printf '%s|%s|%s|%s|%s\n' "$(date +%s)" "$status" "$http_code" "$attempts" "$reason" > "$f" 2>/dev/null || true
}

check_username_network() {
  local username="$1"
  local url="https://www.tiktok.com/@${username}?isUniqueId=true&isSecured=true"
  local attempt=0 max_attempts=$((RETRIES + 1))
  local tmp_body curl_rc http_code body status="UNKNOWN" reason="unclassified" ua
  local -a curl_args

  LAST_STATUS="UNKNOWN"; LAST_HTTP=""; LAST_REASON=""; LAST_ATTEMPTS=0; LAST_SOURCE="network"

  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    tmp_body=$(mktemp)
    ua=$(pick_user_agent)

    curl_args=(
      -sS -L
      -A "$ua"
      --max-time "$TIMEOUT"
      --connect-timeout "$CONNECT_TIMEOUT"
      -w '%{http_code}'
      -o "$tmp_body"
      "$url"
    )
    [[ -n "$PROXY" ]] && curl_args=(--proxy "$PROXY" "${curl_args[@]}")
    [[ "$INSECURE_TLS" -eq 1 ]] && curl_args=(--insecure "${curl_args[@]}")

    http_code=$(curl "${curl_args[@]}")
    curl_rc=$?

    body="$(cat "$tmp_body" 2>/dev/null || true)"
    if [[ "$MAX_BODY_KB" -gt 0 ]]; then
      body="$(printf '%s' "$body" | head -c $((MAX_BODY_KB*1024)))"
    fi

    if [[ -n "$SAVE_BODIES_DIR" ]]; then
      cp "$tmp_body" "$SAVE_BODIES_DIR/${username}.html" 2>/dev/null || true
    fi
    rm -f "$tmp_body"

    if (( curl_rc != 0 )); then
      status="UNKNOWN"
      reason="curl_exit_${curl_rc}"
      http_code=""
      if (( attempt < max_attempts )); then
        [[ "$DELAY" != "0" ]] && sleep "$DELAY"
        continue
      fi
    else
      if printf '%s' "$body" | grep -Fq "\"uniqueId\":\"$username\""; then
        status="TAKEN"; reason="uniqueId_match"
      elif [[ "$http_code" == "403" || "$http_code" == "429" ]] || \
           printf '%s' "$body" | grep -qiE 'captcha|verify|challenge|security check|tiktok-verify-page|access denied|temporarily unavailable'; then
        status="UNKNOWN"; reason="blocked_or_challenge"
      elif [[ "$http_code" =~ ^5[0-9][0-9]$ || "$http_code" == "000" ]]; then
        status="UNKNOWN"; reason="server_error_${http_code}"
        if (( attempt < max_attempts )); then
          [[ "$DELAY" != "0" ]] && sleep "$DELAY"
          continue
        fi
      elif [[ "$http_code" == "404" ]]; then
        status="UNTAKEN"; reason="http_404"
      elif printf '%s' "$body" | grep -qiE "couldn't find this account|user not found|page not available|not found|couldn't find|profile unavailable"; then
        status="UNTAKEN"; reason="not_found_marker"
      else
        if [[ "$STRICT_MODE" -eq 1 ]]; then
          status="UNKNOWN"; reason="no_explicit_not_found_marker"
        else
          status="UNTAKEN"; reason="no_uniqueId_match"
        fi
      fi
    fi

    break
  done

  LAST_STATUS="$status"
  LAST_HTTP="$http_code"
  LAST_REASON="$reason"
  LAST_ATTEMPTS="$attempt"
}

check_username() {
  local username="$1"
  if [[ "$DRY_RUN" -eq 1 ]]; then
    LAST_STATUS="UNKNOWN"; LAST_HTTP=""; LAST_REASON="dry_run_no_request"; LAST_ATTEMPTS=0; LAST_SOURCE="dryrun"
    return 0
  fi
  if cache_lookup "$username"; then
    return 0
  fi
  check_username_network "$username"
  cache_store "$username" "$LAST_STATUS" "$LAST_HTTP" "$LAST_ATTEMPTS" "$LAST_REASON"
}

print_result_line() {
  local username="$1" status="$2" reason="$3" http_code="$4" source="$5"
  [[ "$SUMMARY_ONLY" -eq 1 || "$QUIET" -eq 1 ]] && return 0

  case "$PRINT_FORMAT" in
    tsv)
      printf '%s\t%s\t%s\t%s\t%s\n' "$username" "$status" "${http_code:-}" "$reason" "$source"
      return 0
      ;;
    jsonl)
      printf '{"username":"%s","status":"%s","http_code":"%s","reason":"%s","source":"%s","index":%s,"total":%s}\n' \
        "$(json_escape "$username")" "$(json_escape "$status")" "$(json_escape "$http_code")" "$(json_escape "$reason")" "$(json_escape "$source")" "$PROCESSED" "$TOTAL"
      return 0
      ;;
  esac

  local color="$nc"
  case "$status" in
    TAKEN) color="$red" ;;
    UNTAKEN) color="$green" ;;
    UNKNOWN|INVALID) color="$yellow" ;;
  esac

  printf '%b[%d/%d]%b @%s : %b%s%b' "$bold" "$PROCESSED" "$TOTAL" "$nc" "$username" "$color" "$status" "$nc"
  if [[ -n "$http_code" ]]; then
    printf ' (HTTP %s, %s, %s)\n' "$http_code" "$reason" "$source"
  else
    printf ' (%s, %s)\n' "$reason" "$source"
  fi
}

record_result() {
  local username="$1" status="$2" http_code="$3" attempts="$4" reason="$5" source="$6"
  local now_iso
  now_iso=$(date '+%Y-%m-%dT%H:%M:%S')

  case "$status" in
    TAKEN)   echo "$username" >> "$TAKEN_FILE"; COUNT_TAKEN=$((COUNT_TAKEN + 1)) ;;
    UNTAKEN) echo "$username" >> "$UNTAKEN_FILE"; COUNT_UNTAKEN=$((COUNT_UNTAKEN + 1)) ;;
    UNKNOWN) echo "$username" >> "$UNKNOWN_FILE"; COUNT_UNKNOWN=$((COUNT_UNKNOWN + 1)) ;;
    INVALID) echo "$username" >> "$INVALID_FILE"; COUNT_INVALID=$((COUNT_INVALID + 1)) ;;
  esac
  [[ "$source" == "cache" ]] && COUNT_CACHE_HITS=$((COUNT_CACHE_HITS + 1))
  [[ "$source" == "dryrun" ]] && COUNT_DRYRUN=$((COUNT_DRYRUN + 1))

  printf '%s,%s,%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$username")" \
    "$(csv_escape "$status")" \
    "$(csv_escape "$http_code")" \
    "$(csv_escape "$attempts")" \
    "$(csv_escape "$now_iso")" \
    "$(csv_escape "$reason")" \
    "$(csv_escape "$source")" >> "$RESULTS_CSV"

  printf '{"username":"%s","status":"%s","http_code":"%s","attempts":%s,"timestamp":"%s","reason":"%s","source":"%s"}\n' \
    "$(json_escape "$username")" \
    "$(json_escape "$status")" \
    "$(json_escape "$http_code")" \
    "${attempts:-0}" \
    "$(json_escape "$now_iso")" \
    "$(json_escape "$reason")" \
    "$(json_escape "$source")" >> "$TMP_ALL_RESULTS"

  printf '{"username":"%s","status":"%s","http_code":"%s","attempts":%s,"timestamp":"%s","reason":"%s","source":"%s"}\n' \
    "$(json_escape "$username")" \
    "$(json_escape "$status")" \
    "$(json_escape "$http_code")" \
    "${attempts:-0}" \
    "$(json_escape "$now_iso")" \
    "$(json_escape "$reason")" \
    "$(json_escape "$source")" >> "$RESULTS_NDJSON"
}

run_single_job() {
  local idx="$1" username="$2" outfile="$3"
  local status http reason attempts source

  if [[ "$VALIDATE" -eq 1 ]] && ! is_valid_username "$username"; then
    status="INVALID"; http=""; attempts=0; reason="failed_validation"; source="validation"
  else
    check_username "$username"
    status="$LAST_STATUS"; http="$LAST_HTTP"; attempts="$LAST_ATTEMPTS"; reason="$LAST_REASON"; source="$LAST_SOURCE"
  fi

  {
    printf '%s\n' "$idx"
    printf '%s\n' "$username"
    printf '%s\n' "$status"
    printf '%s\n' "${http:-}"
    printf '%s\n' "$attempts"
    printf '%s\n' "$reason"
    printf '%s\n' "$source"
  } > "$outfile"
}

run_checks_parallel() {
  local idx=0 username outfile
  local active=0

  while IFS= read -r username || [[ -n "$username" ]]; do
    [[ -z "$username" ]] && continue
    idx=$((idx + 1))
    outfile="$JOB_DIR/${idx}.res"

    run_single_job "$idx" "$username" "$outfile" &
    active=$((active + 1))

    if (( active >= WORKERS )); then
      wait -n || true
      active=$((active - 1))
    fi

    [[ "$INTERRUPTED" -eq 1 ]] && break
  done < "$TMP_USERS_WORKLIST"

  wait || true

  local i row r_idx r_user r_status r_http r_attempts r_reason r_source
  for ((i=1; i<=idx; i++)); do
    [[ -f "$JOB_DIR/${i}.res" ]] || continue
    mapfile -t _res_lines < "$JOB_DIR/${i}.res"
    r_idx="${_res_lines[0]:-}"; r_user="${_res_lines[1]:-}"; r_status="${_res_lines[2]:-}"; r_http="${_res_lines[3]:-}"
    r_attempts="${_res_lines[4]:-}"; r_reason="${_res_lines[5]:-}"; r_source="${_res_lines[6]:-}"
    PROCESSED=$((PROCESSED + 1))
    record_result "$r_user" "$r_status" "$r_http" "$r_attempts" "$r_reason" "$r_source"
    print_result_line "$r_user" "$r_status" "$r_reason" "$r_http" "$r_source"
  done
}

run_checks_sequential() {
  local idx=0 username
  local r_idx r_user r_status r_http r_attempts r_reason r_source
  while IFS= read -r username || [[ -n "$username" ]]; do
    [[ -z "$username" ]] && continue
    [[ "$INTERRUPTED" -eq 1 ]] && break
    idx=$((idx + 1))
    run_single_job "$idx" "$username" "$JOB_DIR/$idx.res"

    mapfile -t _res_lines < "$JOB_DIR/$idx.res"
    r_idx="${_res_lines[0]:-}"; r_user="${_res_lines[1]:-}"; r_status="${_res_lines[2]:-}"; r_http="${_res_lines[3]:-}"
    r_attempts="${_res_lines[4]:-}"; r_reason="${_res_lines[5]:-}"; r_source="${_res_lines[6]:-}"
    PROCESSED=$((PROCESSED + 1))
    record_result "$r_user" "$r_status" "$r_http" "$r_attempts" "$r_reason" "$r_source"
    print_result_line "$r_user" "$r_status" "$r_reason" "$r_http" "$r_source"

    if [[ "$DELAY" != "0" && "$PROCESSED" -lt "$TOTAL" ]]; then
      sleep "$DELAY"
    fi
  done < "$TMP_USERS_WORKLIST"
}

run_checks() {
  if [[ "$TOTAL" -eq 0 ]]; then
    return 0
  fi
  if [[ "$WORKERS" -gt 1 && "$DRY_RUN" -eq 0 ]]; then
    run_checks_parallel
  else
    run_checks_sequential
  fi
}

write_json_export() {
  [[ -z "$JSON_PATH" ]] && return 0
  mkdir -p "$(dirname "$JSON_PATH")" 2>/dev/null || true
  {
    echo '['
    if [[ -s "$TMP_ALL_RESULTS" ]]; then
      awk 'NR>1{print prev ","} {prev=$0} END{if(NR) print prev}' "$TMP_ALL_RESULTS"
    fi
    echo ']'
  } > "$JSON_PATH"
}

write_summary() {
  local end_ts elapsed exit_hint
  end_ts=$(date +%s)
  elapsed=$((end_ts - START_TS))
  exit_hint=0
  [[ "$COUNT_UNKNOWN" -gt 0 || "$COUNT_INVALID" -gt 0 ]] && exit_hint=2
  [[ "$INTERRUPTED" -eq 1 ]] && exit_hint=130

  {
    echo "untaken summary"
    echo "==============="
    echo "version: ${VERSION}"
    echo "started_at: ${RUN_TS_HUMAN}"
    echo "total_inputs_after_resume: ${TOTAL}"
    echo "processed: ${PROCESSED}"
    echo "taken: ${COUNT_TAKEN}"
    echo "untaken: ${COUNT_UNTAKEN}"
    echo "unknown: ${COUNT_UNKNOWN}"
    echo "invalid: ${COUNT_INVALID}"
    echo "cache_hits: ${COUNT_CACHE_HITS}"
    echo "resume_skips: ${COUNT_RESUMED_SKIPS}"
    echo "dryrun_records: ${COUNT_DRYRUN}"
    echo "strict_mode: ${STRICT_MODE}"
    echo "validation_enabled: ${VALIDATE}"
    echo "workers: ${WORKERS}"
    echo "timeout_seconds: ${TIMEOUT}"
    echo "connect_timeout_seconds: ${CONNECT_TIMEOUT}"
    echo "retries: ${RETRIES}"
    echo "delay_seconds: ${DELAY}"
    echo "proxy: ${PROXY:-}"
    echo "cache_dir: ${CACHE_DIR:-}"
    echo "cache_ttl_seconds: ${CACHE_TTL}"
    echo "output_dir: ${OUTPUT_DIR}"
    echo "taken_file: ${TAKEN_FILE}"
    echo "untaken_file: ${UNTAKEN_FILE}"
    echo "unknown_file: ${UNKNOWN_FILE}"
    echo "invalid_file: ${INVALID_FILE}"
    echo "csv_file: ${RESULTS_CSV}"
    echo "ndjson_file: ${RESULTS_NDJSON}"
    [[ -n "$JSON_PATH" ]] && echo "json_file: ${JSON_PATH}"
    echo "summary_json_file: ${SUMMARY_JSON_FILE}"
    echo "elapsed_seconds: ${elapsed}"
    echo "interrupted: ${INTERRUPTED}"
    echo "recommended_exit_code: ${exit_hint}"
  } > "$SUMMARY_FILE"

  {
    printf '{\n'
    printf '  "version": "%s",\n' "$(json_escape "$VERSION")"
    printf '  "started_at": "%s",\n' "$(json_escape "$RUN_TS_HUMAN")"
    printf '  "total_inputs_after_resume": %s,\n' "$TOTAL"
    printf '  "processed": %s,\n' "$PROCESSED"
    printf '  "taken": %s,\n' "$COUNT_TAKEN"
    printf '  "untaken": %s,\n' "$COUNT_UNTAKEN"
    printf '  "unknown": %s,\n' "$COUNT_UNKNOWN"
    printf '  "invalid": %s,\n' "$COUNT_INVALID"
    printf '  "cache_hits": %s,\n' "$COUNT_CACHE_HITS"
    printf '  "resume_skips": %s,\n' "$COUNT_RESUMED_SKIPS"
    printf '  "dryrun_records": %s,\n' "$COUNT_DRYRUN"
    printf '  "strict_mode": %s,\n' "$STRICT_MODE"
    printf '  "validation_enabled": %s,\n' "$VALIDATE"
    printf '  "workers": %s,\n' "$WORKERS"
    printf '  "timeout_seconds": %s,\n' "$TIMEOUT"
    printf '  "connect_timeout_seconds": %s,\n' "$CONNECT_TIMEOUT"
    printf '  "retries": %s,\n' "$RETRIES"
    printf '  "delay_seconds": %s,\n' "$DELAY"
    printf '  "cache_ttl_seconds": %s,\n' "$CACHE_TTL"
    printf '  "elapsed_seconds": %s,\n' "$elapsed"
    printf '  "interrupted": %s,\n' "$INTERRUPTED"
    printf '  "recommended_exit_code": %s\n' "$exit_hint"
    printf '}\n'
  } > "$SUMMARY_JSON_FILE"

  echo
  echo -e "${bold}Run complete${nc}"
  echo "  Processed         -> $PROCESSED / $TOTAL"
  [[ "$COUNT_RESUMED_SKIPS" -gt 0 ]] && echo "  Resume skipped    -> $COUNT_RESUMED_SKIPS"
  echo "  Taken   (${COUNT_TAKEN}) -> $TAKEN_FILE"
  echo "  Untaken (${COUNT_UNTAKEN}) -> $UNTAKEN_FILE"
  echo "  Unknown (${COUNT_UNKNOWN}) -> $UNKNOWN_FILE"
  echo "  Invalid (${COUNT_INVALID}) -> $INVALID_FILE"
  echo "  Cache hits        -> $COUNT_CACHE_HITS"
  echo "  CSV               -> $RESULTS_CSV"
  echo "  NDJSON            -> $RESULTS_NDJSON"
  [[ -n "$JSON_PATH" ]] && echo "  JSON              -> $JSON_PATH"
  echo "  Summary TXT       -> $SUMMARY_FILE"
  echo "  Summary JSON      -> $SUMMARY_JSON_FILE"
  echo "  Elapsed           -> ${elapsed}s"
}

main() {
  check_dependencies
  parse_args "$@"
  validate_numeric_flags
  init_colors
  print_banner
  setup_output
  collect_targets
  prepare_worklist
  print_run_config
  run_checks
  write_json_export
  write_summary

  if [[ "$INTERRUPTED" -eq 1 ]]; then
    exit 130
  fi
  if [[ "$COUNT_UNKNOWN" -gt 0 || "$COUNT_INVALID" -gt 0 ]]; then
    exit 2
  fi
  exit 0
}

main "$@"
