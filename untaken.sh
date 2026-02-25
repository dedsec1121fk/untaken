#!/usr/bin/env bash

# untaken - Enhanced TikTok username availability checker
# Original author: Haitham Aouati
# Enhanced CLI/features upgrade

set -uo pipefail

APP_NAME="untaken"
VERSION="3.1.0"

# ---------------- Defaults ----------------
NO_COLOR=0
QUIET=0
APPEND=0
VALIDATE=1
STRICT_MODE=0
SUMMARY_ONLY=0
KEEP_DUPLICATES=0
TIMEOUT=15
RETRIES=2
DELAY=0
USER_AGENT="Mozilla/5.0 (X11; Linux x86_64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/122.0 Safari/537.36"
OUTPUT_DIR=""
CSV_PATH=""
JSON_PATH=""

# ---------------- Inputs ----------------
TARGETS=()      # legacy -u can be username OR file
INPUT_FILES=()
USE_STDIN=0
PIPE_STDIN=0

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

TAKEN_FILE=""
UNTAKEN_FILE=""
UNKNOWN_FILE=""
INVALID_FILE=""
RESULTS_CSV=""
SUMMARY_FILE=""

TMP_ALL_RESULTS=""
TMP_USERS_RAW=""
TMP_USERS_FINAL=""

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
  [[ "$QUIET" -eq 1 ]] && return 0
  clear 2>/dev/null || true
  echo -e "${bold}"
  echo "         _       _           "
  echo " _ _ ___| |_ ___| |_ ___ ___ "
  echo "| | |   |  _| .'| '_| -_|   |"
  echo "|___|_|_|_| |__,|_,_|___|_|_|"
  echo -e "${nc}"
  echo -e " ${cyan}${bold}${APP_NAME}${nc} v${VERSION}"
  echo -e " Original author: Haitham Aouati"
  echo -e " Enhanced CLI build\n"
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

Output options:
  -o, --output-dir <dir>                    Output dir (default: untaken_results_<timestamp>)
      --csv <file>                          Export all results to CSV (default: <output-dir>/results.csv)
      --json <file>                         Export all results to JSON
      --append                              Append to text/csv outputs instead of truncating
      --summary-only                        Show final summary only (no per-item output)

Network / detection:
      --timeout <sec>                       Curl timeout per request (default: 15)
      --retries <n>                         Retries on transient errors (default: 2)
      --delay <sec>                         Delay between checks (default: 0)
      --user-agent <ua>                     Custom User-Agent
      --strict                              Classify as UNTAKEN only on explicit “not found” clues

UI / general:
  -q, --quiet                               Quiet mode
      --no-color                            Disable ANSI colors
  -V, --version                             Print version
  -h, --help                                Show help

Examples:
  untaken -u mybrandname
  untaken -u usernames.txt --delay 0.5 --retries 3
  untaken -f names.txt --strict --json run/results.json
  printf "alpha\nbeta\n" | untaken --stdin -o runs/demo
EOF
}

show_version() { echo "${APP_NAME} ${VERSION}"; }

check_dependencies() {
  local missing=0
  for cmd in curl grep sed awk wc date mktemp; do
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
}
trap cleanup EXIT

trim() {
  local s="$1"
  s="${s//$'\r'/}"
  s="$(printf '%s' "$s" | sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//')"
  printf '%s' "$s"
}

normalize_username() {
  local u
  u=$(trim "$1")
  # Skip comments / blanks
  [[ -z "$u" ]] && return 1
  [[ "$u" =~ ^# ]] && return 1
  # Take first token if accidental extra spacing/comments after a username
  u="${u%%[[:space:]]*}"
  # Strip leading @
  u="${u#@}"
  # Strip URL-ish prefixes if user pasted profile URL
  u="${u#https://www.tiktok.com/@}"
  u="${u#http://www.tiktok.com/@}"
  u="${u#www.tiktok.com/@}"
  u="${u#tiktok.com/@}"
  # Cut off path/query fragments
  u="${u%%\?*}"
  u="${u%%/*}"
  u=$(trim "$u")
  [[ -z "$u" ]] && return 1
  printf '%s' "$u"
  return 0
}

is_valid_username() {
  local u="$1"
  # TikTok usernames are commonly 2-24 chars; allow letters/numbers/underscore/dot
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

parse_args() {
  while [[ $# -gt 0 ]]; do
    case "$1" in
      -u|--username)
        [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }
        TARGETS+=("$2")
        shift 2
        ;;
      -f|--file)
        [[ $# -lt 2 ]] && { err "Missing file for $1"; exit 1; }
        INPUT_FILES+=("$2")
        shift 2
        ;;
      --stdin)
        USE_STDIN=1
        shift
        ;;
      --keep-duplicates)
        KEEP_DUPLICATES=1
        shift
        ;;
      --no-validate)
        VALIDATE=0
        shift
        ;;
      -o|--output-dir)
        [[ $# -lt 2 ]] && { err "Missing directory for $1"; exit 1; }
        OUTPUT_DIR="$2"
        shift 2
        ;;
      --csv)
        [[ $# -lt 2 ]] && { err "Missing file path for $1"; exit 1; }
        CSV_PATH="$2"
        shift 2
        ;;
      --json)
        [[ $# -lt 2 ]] && { err "Missing file path for $1"; exit 1; }
        JSON_PATH="$2"
        shift 2
        ;;
      --append)
        APPEND=1
        shift
        ;;
      --summary-only)
        SUMMARY_ONLY=1
        shift
        ;;
      --timeout)
        [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }
        TIMEOUT="$2"
        shift 2
        ;;
      --retries)
        [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }
        RETRIES="$2"
        shift 2
        ;;
      --delay)
        [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }
        DELAY="$2"
        shift 2
        ;;
      --user-agent)
        [[ $# -lt 2 ]] && { err "Missing value for $1"; exit 1; }
        USER_AGENT="$2"
        shift 2
        ;;
      --strict)
        STRICT_MODE=1
        shift
        ;;
      -q|--quiet)
        QUIET=1
        shift
        ;;
      --no-color)
        NO_COLOR=1
        shift
        ;;
      -V|--version)
        show_version
        exit 0
        ;;
      -h|--help)
        usage
        exit 0
        ;;
      *)
        err "Unknown option: $1"
        usage
        exit 1
        ;;
    esac
  done
}

validate_numeric_flags() {
  [[ "$TIMEOUT" =~ ^[0-9]+([.][0-9]+)?$ ]] || { err "--timeout must be numeric"; exit 1; }
  [[ "$RETRIES" =~ ^[0-9]+$ ]] || { err "--retries must be a non-negative integer"; exit 1; }
  [[ "$DELAY" =~ ^[0-9]+([.][0-9]+)?$ ]] || { err "--delay must be numeric"; exit 1; }
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

  mkdir -p "$(dirname "$RESULTS_CSV")" 2>/dev/null || true
  [[ -n "$JSON_PATH" ]] && mkdir -p "$(dirname "$JSON_PATH")" 2>/dev/null || true

  if [[ "$APPEND" -eq 0 ]]; then
    : > "$TAKEN_FILE"
    : > "$UNTAKEN_FILE"
    : > "$UNKNOWN_FILE"
    : > "$INVALID_FILE"
    : > "$RESULTS_CSV"
  else
    touch "$TAKEN_FILE" "$UNTAKEN_FILE" "$UNKNOWN_FILE" "$INVALID_FILE" "$RESULTS_CSV"
  fi

  # CSV header only when file is empty
  if [[ ! -s "$RESULTS_CSV" ]]; then
    echo 'username,status,http_code,attempts,timestamp,reason' > "$RESULTS_CSV"
  fi

  TMP_ALL_RESULTS=$(mktemp)
  TMP_USERS_RAW=$(mktemp)
  TMP_USERS_FINAL=$(mktemp)
}

collect_targets() {
  local item line normalized

  # Legacy/primary -u values: username OR file path
  for item in "${TARGETS[@]}"; do
    if [[ -f "$item" ]]; then
      INPUT_FILES+=("$item")
    else
      echo "$item" >> "$TMP_USERS_RAW"
    fi
  done

  # Explicit files
  for item in "${INPUT_FILES[@]}"; do
    if [[ ! -f "$item" ]]; then
      err "Input file not found: $item"
      exit 1
    fi
    while IFS= read -r line || [[ -n "$line" ]]; do
      echo "$line" >> "$TMP_USERS_RAW"
    done < "$item"
  done

  # Detect piped stdin automatically
  if [[ ! -t 0 ]]; then
    PIPE_STDIN=1
  fi

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

  # Normalize and optionally dedupe (preserve order)
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

  TOTAL=$(grep -cv '^[[:space:]]*$' "$TMP_USERS_FINAL" || true)
  if [[ "$TOTAL" -eq 0 ]]; then
    err "No valid input lines found after normalization."
    exit 1
  fi
}

print_run_config() {
  [[ "$QUIET" -eq 1 ]] && return 0
  echo -e "${bold}Loaded ${TOTAL} usernames${nc}"
  echo -e "Output directory: ${blue}${OUTPUT_DIR}${nc}"
  echo -e "CSV export: ${blue}${RESULTS_CSV}${nc}"
  [[ -n "$JSON_PATH" ]] && echo -e "JSON export: ${blue}${JSON_PATH}${nc}"
  echo -e "Timeout=${TIMEOUT}s | Retries=${RETRIES} | Delay=${DELAY}s | Strict=${STRICT_MODE} | Validate=${VALIDATE}"
  echo
}

# Returns data via globals:
#   LAST_STATUS, LAST_HTTP, LAST_REASON, LAST_ATTEMPTS
check_username() {
  local username="$1"
  local url="https://www.tiktok.com/@${username}?isUniqueId=true&isSecured=true"
  local attempt=0 max_attempts=$((RETRIES + 1))
  local tmp_body curl_rc http_code body
  local status="UNKNOWN" reason="unclassified"

  LAST_STATUS="UNKNOWN"; LAST_HTTP=""; LAST_REASON=""; LAST_ATTEMPTS=0

  while (( attempt < max_attempts )); do
    attempt=$((attempt + 1))
    tmp_body=$(mktemp)

    http_code=$(curl -sS -L \
      -A "$USER_AGENT" \
      --max-time "$TIMEOUT" \
      -w '%{http_code}' \
      -o "$tmp_body" \
      "$url")
    curl_rc=$?

    body="$(cat "$tmp_body" 2>/dev/null || true)"
    rm -f "$tmp_body"

    if (( curl_rc != 0 )); then
      status="UNKNOWN"
      reason="curl_exit_${curl_rc}"
      LAST_HTTP=""
      if (( attempt < max_attempts )); then
        [[ "$DELAY" != "0" ]] && sleep "$DELAY"
        continue
      fi
    else
      LAST_HTTP="$http_code"

      if printf '%s' "$body" | grep -Fq "\"uniqueId\":\"$username\""; then
        status="TAKEN"
        reason="uniqueId_match"
      elif [[ "$http_code" == "403" || "$http_code" == "429" ]] || \
           printf '%s' "$body" | grep -qiE 'captcha|verify|challenge|security check|tiktok-verify-page|access denied'; then
        status="UNKNOWN"
        reason="blocked_or_challenge"
      elif [[ "$http_code" =~ ^5[0-9][0-9]$ || "$http_code" == "000" ]]; then
        status="UNKNOWN"
        reason="server_error_${http_code}"
        if (( attempt < max_attempts )); then
          [[ "$DELAY" != "0" ]] && sleep "$DELAY"
          continue
        fi
      else
        if printf '%s' "$body" | grep -qiE "couldn't find this account|user not found|page not available|not found"; then
          status="UNTAKEN"
          reason="not_found_marker"
        else
          if [[ "$STRICT_MODE" -eq 1 ]]; then
            status="UNKNOWN"
            reason="no_explicit_not_found_marker"
          else
            status="UNTAKEN"
            reason="no_uniqueId_match"
          fi
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

print_result_line() {
  local username="$1" status="$2" reason="$3" http_code="$4"
  [[ "$SUMMARY_ONLY" -eq 1 || "$QUIET" -eq 1 ]] && return 0

  local color="$nc"
  case "$status" in
    TAKEN) color="$red" ;;
    UNTAKEN) color="$green" ;;
    UNKNOWN|INVALID) color="$yellow" ;;
  esac

  printf '%b[%d/%d]%b @%s : %b%s%b' "$bold" "$PROCESSED" "$TOTAL" "$nc" "$username" "$color" "$status" "$nc"
  if [[ -n "$http_code" ]]; then
    printf ' (HTTP %s, %s)\n' "$http_code" "$reason"
  else
    printf ' (%s)\n' "$reason"
  fi
}

record_result() {
  local username="$1" status="$2" http_code="$3" attempts="$4" reason="$5"
  local now_iso
  now_iso=$(date '+%Y-%m-%dT%H:%M:%S')

  case "$status" in
    TAKEN)
      echo "$username" >> "$TAKEN_FILE"
      COUNT_TAKEN=$((COUNT_TAKEN + 1))
      ;;
    UNTAKEN)
      echo "$username" >> "$UNTAKEN_FILE"
      COUNT_UNTAKEN=$((COUNT_UNTAKEN + 1))
      ;;
    UNKNOWN)
      echo "$username" >> "$UNKNOWN_FILE"
      COUNT_UNKNOWN=$((COUNT_UNKNOWN + 1))
      ;;
    INVALID)
      echo "$username" >> "$INVALID_FILE"
      COUNT_INVALID=$((COUNT_INVALID + 1))
      ;;
  esac

  printf '%s,%s,%s,%s,%s,%s\n' \
    "$(csv_escape "$username")" \
    "$(csv_escape "$status")" \
    "$(csv_escape "$http_code")" \
    "$(csv_escape "$attempts")" \
    "$(csv_escape "$now_iso")" \
    "$(csv_escape "$reason")" >> "$RESULTS_CSV"

  printf '{"username":"%s","status":"%s","http_code":"%s","attempts":%s,"timestamp":"%s","reason":"%s"}\n' \
    "$(json_escape "$username")" \
    "$(json_escape "$status")" \
    "$(json_escape "$http_code")" \
    "${attempts:-0}" \
    "$(json_escape "$now_iso")" \
    "$(json_escape "$reason")" >> "$TMP_ALL_RESULTS"
}

run_checks() {
  local username

  while IFS= read -r username || [[ -n "$username" ]]; do
    [[ -z "$username" ]] && continue
    PROCESSED=$((PROCESSED + 1))

    if [[ "$VALIDATE" -eq 1 ]] && ! is_valid_username "$username"; then
      record_result "$username" "INVALID" "" 0 "failed_validation"
      print_result_line "$username" "INVALID" "failed_validation" ""
      if [[ "$DELAY" != "0" && "$PROCESSED" -lt "$TOTAL" ]]; then
        sleep "$DELAY"
      fi
      continue
    fi

    check_username "$username"
    record_result "$username" "$LAST_STATUS" "$LAST_HTTP" "$LAST_ATTEMPTS" "$LAST_REASON"
    print_result_line "$username" "$LAST_STATUS" "$LAST_REASON" "$LAST_HTTP"

    if [[ "$DELAY" != "0" && "$PROCESSED" -lt "$TOTAL" ]]; then
      sleep "$DELAY"
    fi
  done < "$TMP_USERS_FINAL"
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

  {
    echo "untaken summary"
    echo "==============="
    echo "version: ${VERSION}"
    echo "started_at: ${RUN_TS_HUMAN}"
    echo "total_inputs: ${TOTAL}"
    echo "processed: ${PROCESSED}"
    echo "taken: ${COUNT_TAKEN}"
    echo "untaken: ${COUNT_UNTAKEN}"
    echo "unknown: ${COUNT_UNKNOWN}"
    echo "invalid: ${COUNT_INVALID}"
    echo "strict_mode: ${STRICT_MODE}"
    echo "validation_enabled: ${VALIDATE}"
    echo "timeout_seconds: ${TIMEOUT}"
    echo "retries: ${RETRIES}"
    echo "delay_seconds: ${DELAY}"
    echo "output_dir: ${OUTPUT_DIR}"
    echo "taken_file: ${TAKEN_FILE}"
    echo "untaken_file: ${UNTAKEN_FILE}"
    echo "unknown_file: ${UNKNOWN_FILE}"
    echo "invalid_file: ${INVALID_FILE}"
    echo "csv_file: ${RESULTS_CSV}"
    [[ -n "$JSON_PATH" ]] && echo "json_file: ${JSON_PATH}"
    echo "elapsed_seconds: ${elapsed}"
    echo "recommended_exit_code: ${exit_hint}"
  } > "$SUMMARY_FILE"

  echo
  echo -e "${bold}Run complete${nc}"
  echo "  Taken   (${COUNT_TAKEN}) -> $TAKEN_FILE"
  echo "  Untaken (${COUNT_UNTAKEN}) -> $UNTAKEN_FILE"
  echo "  Unknown (${COUNT_UNKNOWN}) -> $UNKNOWN_FILE"
  echo "  Invalid (${COUNT_INVALID}) -> $INVALID_FILE"
  echo "  CSV               -> $RESULTS_CSV"
  [[ -n "$JSON_PATH" ]] && echo "  JSON              -> $JSON_PATH"
  echo "  Summary           -> $SUMMARY_FILE"
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
  print_run_config
  run_checks
  write_json_export
  write_summary

  if [[ "$COUNT_UNKNOWN" -gt 0 || "$COUNT_INVALID" -gt 0 ]]; then
    exit 2
  fi
  exit 0
}

main "$@"
