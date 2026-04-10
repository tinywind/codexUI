#!/usr/bin/env bash
set -euo pipefail

SELF_DIR="$(cd "$(dirname "$(readlink -f "$0")")" && pwd)"
SYNC_SCRIPT="$SELF_DIR/sync-auth.sh"
SERVICE_BASE_DIR="$HOME/.codex-auth-launcher/services"
CONFIG_BASE_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/codex-auth-launcher"
BATCH_STATE_DIR="$CONFIG_BASE_DIR/batches"
DEFAULT_PROFILES_DIR="$HOME/.codex-auth-launcher/profiles"
DEFAULT_PORT_START=8051

declare -a BATCH_PROFILE_DIRS=()
declare -a BATCH_PROFILE_NAMES=()
declare -a MATCHED_SERVICE_NAMES=()
declare -a STATE_SERVICE_NAMES=()
declare -a STATE_PROFILE_DIRS=()
declare -a STATE_PORTS=()

STATE_EXISTS=0
STATE_BATCH_ID=""
STATE_DIR=""
STATE_META_FILE=""
STATE_MAP_FILE=""
STATE_FOLDER_PATH=""
STATE_PREFIX=""
STATE_PORT_START=""
STATE_HOSTNAME=""
STATE_MATCH_INDEX=-1
PREFERRED_SERVICE_NAME=""
ACTIVE_SERVICE_PID=""
BATCH_FOLDER_RESOLVED=""

usage() {
  cat >&2 <<'EOF'
Usage:
  codex-web-auth start <profile-name> --port <port> [--hostname <host>]
  codex-web-auth start-folder [profiles-dir] [--port-start <port>] [--hostname <host>] [--prefix <prefix>]
  codex-web-auth stop <profile-name>
  codex-web-auth stop-folder [profiles-dir] [--prefix <prefix>]
  codex-web-auth restart <profile-name>
  codex-web-auth restart-folder [profiles-dir] [--prefix <prefix>]
  codex-web-auth status [profile-name]
  codex-web-auth status-folder [profiles-dir] [--prefix <prefix>]
  codex-web-auth sync <profile-name>
  codex-web-auth sync-folder [profiles-dir]
  codex-web-auth list
  codex-web-auth logs <profile-name> [line-count]

Defaults:
  profiles-dir: ~/.codex-auth-launcher/profiles
  port-start:   8051
EOF
  exit 1
}

sanitize_slug() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -cs 'a-z0-9' '-' | sed 's/^-//; s/-$//'
}

read_profile_field() {
  local profile_json="$1"
  local field="$2"
  python3 -c "import json,sys; d=json.load(open(sys.argv[1])); v=d.get(sys.argv[2]); print(v if v is not None else '')" "$profile_json" "$field" 2>/dev/null
}

clear_batch_state() {
  STATE_EXISTS=0
  STATE_BATCH_ID=""
  STATE_DIR=""
  STATE_META_FILE=""
  STATE_MAP_FILE=""
  STATE_FOLDER_PATH=""
  STATE_PREFIX=""
  STATE_PORT_START=""
  STATE_HOSTNAME=""
  STATE_MATCH_INDEX=-1
  STATE_SERVICE_NAMES=()
  STATE_PROFILE_DIRS=()
  STATE_PORTS=()
}

set_batch_state_paths() {
  local folder_path="$1"
  local resolved_prefix="$2"
  local prefix_slug
  local batch_hash

  prefix_slug="$(sanitize_slug "$resolved_prefix")"
  batch_hash="$(printf '%s|%s' "$folder_path" "$resolved_prefix" | sha256sum | cut -c1-10)"

  STATE_BATCH_ID="${prefix_slug:-batch}-$batch_hash"
  STATE_DIR="$BATCH_STATE_DIR/$STATE_BATCH_ID"
  STATE_META_FILE="$STATE_DIR/batch.env"
  STATE_MAP_FILE="$STATE_DIR/services.tsv"
}

load_batch_state() {
  local folder_path="$1"
  local resolved_prefix="$2"
  local service_name profile_dir port

  clear_batch_state
  set_batch_state_paths "$folder_path" "$resolved_prefix"

  if [ ! -f "$STATE_META_FILE" ] || [ ! -f "$STATE_MAP_FILE" ]; then
    return 1
  fi

  # shellcheck disable=SC1090
  source "$STATE_META_FILE"

  STATE_EXISTS=1
  STATE_FOLDER_PATH="${FOLDER_PATH:-$folder_path}"
  STATE_PREFIX="${SERVICE_PREFIX:-$resolved_prefix}"
  STATE_PORT_START="${PORT_START:-}"
  STATE_HOSTNAME="${HOSTNAME:-}"

  while IFS=$'\t' read -r service_name profile_dir port; do
    if [ -z "$service_name" ]; then
      continue
    fi
    STATE_SERVICE_NAMES+=("$service_name")
    STATE_PROFILE_DIRS+=("$profile_dir")
    STATE_PORTS+=("$port")
  done < "$STATE_MAP_FILE"
}

save_batch_state() {
  local folder_path="$1"
  local resolved_prefix="$2"
  local port_start="$3"
  local hostname="$4"
  local updated_at index

  set_batch_state_paths "$folder_path" "$resolved_prefix"
  mkdir -p "$STATE_DIR"
  chmod 700 "$CONFIG_BASE_DIR" "$BATCH_STATE_DIR" "$STATE_DIR" 2>/dev/null || true
  updated_at="$(date -Iseconds)"

  {
    printf 'BATCH_ID=%q\n' "$STATE_BATCH_ID"
    printf 'FOLDER_PATH=%q\n' "$folder_path"
    printf 'SERVICE_PREFIX=%q\n' "$resolved_prefix"
    printf 'PORT_START=%q\n' "$port_start"
    printf 'HOSTNAME=%q\n' "$hostname"
    printf 'UPDATED_AT=%q\n' "$updated_at"
  } > "$STATE_META_FILE"

  : > "$STATE_MAP_FILE"
  for index in "${!STATE_SERVICE_NAMES[@]}"; do
    printf '%s\t%s\t%s\n' "${STATE_SERVICE_NAMES[$index]}" "${STATE_PROFILE_DIRS[$index]}" "${STATE_PORTS[$index]}" >> "$STATE_MAP_FILE"
  done

  chmod 600 "$STATE_META_FILE" "$STATE_MAP_FILE"
  STATE_EXISTS=1
  STATE_FOLDER_PATH="$folder_path"
  STATE_PREFIX="$resolved_prefix"
  STATE_PORT_START="$port_start"
  STATE_HOSTNAME="$hostname"
}

find_state_index_by_profile_dir() {
  local profile_dir="$1"
  local index

  STATE_MATCH_INDEX=-1

  for index in "${!STATE_PROFILE_DIRS[@]}"; do
    if [ "${STATE_PROFILE_DIRS[$index]}" = "$profile_dir" ]; then
      STATE_MATCH_INDEX="$index"
      return 0
    fi
  done

  return 1
}

profile_is_in_current_folder() {
  local profile_dir="$1"
  local current

  for current in "${BATCH_PROFILE_DIRS[@]}"; do
    if [ "$current" = "$profile_dir" ]; then
      return 0
    fi
  done

  return 1
}

append_state_entry() {
  local service_name="$1"
  local profile_dir="$2"
  local port="$3"

  STATE_SERVICE_NAMES+=("$service_name")
  STATE_PROFILE_DIRS+=("$profile_dir")
  STATE_PORTS+=("$port")
}

remove_state_entry_by_index() {
  local remove_index="$1"
  local new_names=() new_dirs=() new_ports=()
  local index

  for index in "${!STATE_SERVICE_NAMES[@]}"; do
    if [ "$index" -eq "$remove_index" ]; then
      continue
    fi
    new_names+=("${STATE_SERVICE_NAMES[$index]}")
    new_dirs+=("${STATE_PROFILE_DIRS[$index]}")
    new_ports+=("${STATE_PORTS[$index]}")
  done

  STATE_SERVICE_NAMES=("${new_names[@]+"${new_names[@]}"}")
  STATE_PROFILE_DIRS=("${new_dirs[@]+"${new_dirs[@]}"}")
  STATE_PORTS=("${new_ports[@]+"${new_ports[@]}"}")
}

next_batch_port() {
  local port_start="$1"
  local candidate_port port used

  candidate_port="$port_start"

  while :; do
    used=0

    for port in "${STATE_PORTS[@]+"${STATE_PORTS[@]}"}"; do
      if [ "$port" = "$candidate_port" ]; then
        used=1
        break
      fi
    done

    if [ "$used" -eq 0 ] && ! listener_is_running_on_port "$candidate_port"; then
      printf '%s' "$candidate_port"
      return
    fi

    candidate_port="$((candidate_port + 1))"
  done
}

ensure_service_name() {
  local service_name="$1"

  if [[ ! "$service_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]; then
    echo "Invalid service name: $service_name" >&2
    return 1
  fi
}

service_root() {
  printf '%s/%s' "$SERVICE_BASE_DIR" "$1"
}

meta_file() {
  printf '%s/service.env' "$(service_root "$1")"
}

pid_file() {
  printf '%s/service.pid' "$(service_root "$1")"
}

log_file() {
  printf '%s/service.log' "$(service_root "$1")"
}

listener_pid_by_port() {
  local port="$1"
  local output

  output="$(ss -ltnp "( sport = :$port )" 2>/dev/null || true)"
  printf '%s\n' "$output" | sed -n 's/.*pid=\([0-9][0-9]*\).*/\1/p' | sed -n '1p'
}

listener_is_running_on_port() {
  local port="$1"
  local pid

  pid="$(listener_pid_by_port "$port")"
  [ -n "$pid" ]
}

refresh_service_pid_file() {
  local service_name="$1"
  local listener_pid

  if ! load_service_meta "$service_name" >/dev/null 2>&1; then
    return 1
  fi

  listener_pid="$(listener_pid_by_port "$PORT")"
  if [ -n "$listener_pid" ]; then
    printf '%s\n' "$listener_pid" > "$(pid_file "$service_name")"
    chmod 600 "$(pid_file "$service_name")" 2>/dev/null || true
  fi

  ACTIVE_SERVICE_PID="$listener_pid"
  [ -n "$listener_pid" ]
}

is_pid_running() {
  kill -0 "$1" >/dev/null 2>&1
}

load_service_meta() {
  local service_name="$1"
  local file

  file="$(meta_file "$service_name")"

  if [ ! -f "$file" ]; then
    echo "Service metadata not found for: $service_name" >&2
    return 1
  fi

  # shellcheck disable=SC1090
  source "$file"
}

service_has_metadata() {
  [ -f "$(meta_file "$1")" ]
}

service_is_running() {
  local service_name="$1"

  if ! service_has_metadata "$service_name"; then
    return 1
  fi

  refresh_service_pid_file "$service_name" >/dev/null 2>&1 || return 1
}

list_all_service_names() {
  local root

  if [ ! -d "$SERVICE_BASE_DIR" ]; then
    return 0
  fi

  for root in "$SERVICE_BASE_DIR"/*; do
    if [ -d "$root" ]; then
      basename "$root"
    fi
  done
}

resolve_profile_dir_for_name() {
  local profile_name="$1"
  local candidate

  candidate="$DEFAULT_PROFILES_DIR/$profile_name"
  if [ -d "$candidate" ] && [ -f "$candidate/profile.json" ]; then
    readlink -f "$candidate"
    return 0
  fi

  if [ -d "$profile_name" ] && [ -f "$profile_name/profile.json" ]; then
    readlink -f "$profile_name"
    return 0
  fi

  echo "Profile not found: $profile_name" >&2
  return 1
}

collect_folder_profiles() {
  local folder_input="$1"
  local resolved_folder entry profile_json

  if [ ! -d "$folder_input" ]; then
    echo "Profiles folder not found: $folder_input" >&2
    return 1
  fi

  resolved_folder="$(readlink -f "$folder_input")"

  BATCH_PROFILE_DIRS=()
  BATCH_PROFILE_NAMES=()

  for entry in "$resolved_folder"/*/; do
    if [ ! -d "$entry" ]; then
      continue
    fi
    profile_json="$entry/profile.json"
    if [ -f "$profile_json" ]; then
      BATCH_PROFILE_DIRS+=("$(readlink -f "$entry")")
      BATCH_PROFILE_NAMES+=("$(basename "$entry")")
    fi
  done

  if [ "${#BATCH_PROFILE_DIRS[@]}" -eq 0 ]; then
    echo "No profiles found in: $resolved_folder" >&2
    return 1
  fi

  BATCH_FOLDER_RESOLVED="$resolved_folder"
}

build_folder_service_prefix() {
  local folder_path="$1"
  local explicit_prefix="${2:-}"
  local folder_slug folder_hash prefix_slug

  if [ -n "$explicit_prefix" ]; then
    prefix_slug="$(sanitize_slug "$explicit_prefix")"
    printf '%s' "${prefix_slug:-batch}"
    return
  fi

  folder_slug="$(sanitize_slug "$(basename "$folder_path")")"
  folder_hash="$(printf '%s' "$folder_path" | sha256sum | cut -c1-8)"
  printf 'cx-%s-%s' "${folder_slug:-folder}" "$folder_hash"
}

build_folder_service_name() {
  local service_prefix="$1"
  local profile_name="$2"
  local slug

  slug="$(sanitize_slug "$profile_name")"
  printf '%s-%s' "$service_prefix" "${slug:-profile}"
}

print_service_status() {
  local service_name="$1"
  local root

  root="$(service_root "$service_name")"

  if [ ! -d "$root" ]; then
    echo "$service_name: missing"
    return
  fi

  load_service_meta "$service_name" 2>/dev/null || {
    echo "$service_name: no metadata"
    return
  }

  if refresh_service_pid_file "$service_name" >/dev/null 2>&1; then
    echo "$SERVICE_NAME: running pid=$ACTIVE_SERVICE_PID url=http://${HOSTNAME:-127.0.0.1}:$PORT profile=${PROFILE_NAME:-} codex_home=${CODEX_HOME_PATH:-}"
  else
    echo "$SERVICE_NAME: stopped url=http://${HOSTNAME:-127.0.0.1}:$PORT profile=${PROFILE_NAME:-} codex_home=${CODEX_HOME_PATH:-}"
  fi
}

sync_profile() {
  local profile_dir="$1"

  if [ ! -f "$profile_dir/profile.json" ]; then
    echo "No profile.json in: $profile_dir" >&2
    return 1
  fi

  bash "$SYNC_SCRIPT" "$profile_dir"
}

start_service() {
  local service_name="$1"
  local profile_dir="$2"
  local port=""
  local hostname="0.0.0.0"

  shift 2

  ensure_service_name "$service_name"

  local profile_json="$profile_dir/profile.json"
  if [ ! -f "$profile_json" ]; then
    echo "profile.json not found in: $profile_dir" >&2
    return 1
  fi

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port)
        port="$2"; shift 2 ;;
      --hostname)
        hostname="$2"; shift 2 ;;
      *)
        shift ;;
    esac
  done

  if [ -z "$port" ]; then
    echo "The start command requires --port." >&2
    return 1
  fi

  local codex_home profile_name
  codex_home="$(read_profile_field "$profile_json" "codexHome")"
  profile_name="$(read_profile_field "$profile_json" "profileName")"

  if [ -z "$codex_home" ]; then
    echo "codexHome not set in profile: $profile_dir" >&2
    return 1
  fi

  mkdir -p "$SERVICE_BASE_DIR"

  local root meta pid_path log_path started_at listener_pid pid attempt

  root="$(service_root "$service_name")"
  meta="$(meta_file "$service_name")"
  pid_path="$(pid_file "$service_name")"
  log_path="$(log_file "$service_name")"
  started_at="$(date -Iseconds)"

  mkdir -p "$root"
  chmod 700 "$root"

  if refresh_service_pid_file "$service_name" >/dev/null 2>&1; then
    echo "Service is already running: $service_name (pid $ACTIVE_SERVICE_PID)" >&2
    return 0
  fi

  listener_pid="$(listener_pid_by_port "$port")"
  if [ -n "$listener_pid" ]; then
    echo "Port $port is already in use by pid $listener_pid; cannot start $service_name" >&2
    return 1
  fi

  sync_profile "$profile_dir" 2>/dev/null || echo "Auth sync skipped for $profile_name" >&2

  : > "$log_path"

  nohup env \
    BROWSER=/bin/true \
    CODEX_HOME="$codex_home" \
    codexui --port "$port" --no-tunnel --no-open --no-login --no-password \
    </dev/null >> "$log_path" 2>&1 &
  pid="$!"

  listener_pid=""
  for attempt in $(seq 1 20); do
    listener_pid="$(listener_pid_by_port "$port")"
    if [ -n "$listener_pid" ]; then
      break
    fi
    if ! is_pid_running "$pid"; then
      break
    fi
    sleep 1
  done

  if [ -z "$listener_pid" ]; then
    echo "Service failed to start: $service_name" >&2
    echo "Log file: $log_path" >&2
    tail -20 "$log_path" >&2 2>/dev/null || true
    return 1
  fi

  {
    printf 'SERVICE_NAME=%q\n' "$service_name"
    printf 'PROFILE_DIR=%q\n' "$profile_dir"
    printf 'PROFILE_NAME=%q\n' "$profile_name"
    printf 'CODEX_HOME_PATH=%q\n' "$codex_home"
    printf 'PORT=%q\n' "$port"
    printf 'HOSTNAME=%q\n' "$hostname"
    printf 'PID=%q\n' "$listener_pid"
    printf 'PID_FILE=%q\n' "$pid_path"
    printf 'LOG_FILE=%q\n' "$log_path"
    printf 'STARTED_AT=%q\n' "$started_at"
  } > "$meta"
  chmod 600 "$meta"
  printf '%s\n' "$listener_pid" > "$pid_path"
  chmod 600 "$pid_path"

  echo "Started $service_name" >&2
  echo "  pid: $listener_pid" >&2
  echo "  url: http://$hostname:$port" >&2
  echo "  profile: $profile_name" >&2
  echo "  codex_home: $codex_home" >&2
  echo "  log: $log_path" >&2
}

stop_service() {
  local service_name="$1"
  local target_pid

  ensure_service_name "$service_name"

  if ! load_service_meta "$service_name" 2>/dev/null; then
    echo "No metadata for service: $service_name" >&2
    return 0
  fi

  target_pid="$(listener_pid_by_port "$PORT")"

  if [ -z "$target_pid" ]; then
    rm -f "$(pid_file "$service_name")"
    echo "Service was already stopped: $service_name" >&2
    return 0
  fi

  kill "$target_pid" 2>/dev/null || true

  local attempt
  for attempt in $(seq 1 10); do
    if ! listener_is_running_on_port "$PORT"; then
      rm -f "$(pid_file "$service_name")"
      echo "Stopped $service_name" >&2
      return 0
    fi
    sleep 1
  done

  echo "Service did not stop within 10 seconds: $service_name (pid $target_pid)" >&2
  return 1
}

start_folder_services() {
  local folder_input="${1:-$DEFAULT_PROFILES_DIR}"
  local port_start=""
  local hostname=""
  local service_prefix=""
  local resolved_prefix
  local profile_dir profile_name service_name port
  local started_names=()
  local index state_loaded=0

  shift 2>/dev/null || true

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --port-start)
        port_start="$2"; shift 2 ;;
      --hostname)
        hostname="$2"; shift 2 ;;
      --prefix)
        service_prefix="$2"; shift 2 ;;
      *)
        shift ;;
    esac
  done

  collect_folder_profiles "$folder_input" || return 1
  resolved_prefix="$(build_folder_service_prefix "$BATCH_FOLDER_RESOLVED" "$service_prefix")"

  if load_batch_state "$BATCH_FOLDER_RESOLVED" "$resolved_prefix"; then
    state_loaded=1
  fi

  if [ "$state_loaded" -eq 1 ]; then
    if [ -z "$port_start" ]; then
      port_start="$STATE_PORT_START"
    elif [ -n "$STATE_PORT_START" ] && [ "$port_start" != "$STATE_PORT_START" ]; then
      echo "Keeping saved port start $STATE_PORT_START for batch consistency." >&2
      port_start="$STATE_PORT_START"
    fi
  fi

  if [ -z "$port_start" ]; then
    port_start="$DEFAULT_PORT_START"
  fi

  if [ -z "$hostname" ]; then
    hostname="${STATE_HOSTNAME:-0.0.0.0}"
  fi

  echo "Starting codexUI batch from: $BATCH_FOLDER_RESOLVED" >&2
  echo "Batch service prefix: $resolved_prefix" >&2
  echo "Port start: $port_start" >&2

  for ((index=${#STATE_PROFILE_DIRS[@]}-1; index>=0; index--)); do
    if ! profile_is_in_current_folder "${STATE_PROFILE_DIRS[$index]}"; then
      echo "Profile removed, stopping stale service: ${STATE_SERVICE_NAMES[$index]}" >&2
      if service_has_metadata "${STATE_SERVICE_NAMES[$index]}"; then
        stop_service "${STATE_SERVICE_NAMES[$index]}" || true
      fi
      remove_state_entry_by_index "$index"
    fi
  done

  for index in "${!BATCH_PROFILE_DIRS[@]}"; do
    profile_dir="${BATCH_PROFILE_DIRS[$index]}"
    profile_name="${BATCH_PROFILE_NAMES[$index]}"

    if find_state_index_by_profile_dir "$profile_dir"; then
      service_name="${STATE_SERVICE_NAMES[$STATE_MATCH_INDEX]}"
      port="${STATE_PORTS[$STATE_MATCH_INDEX]}"

      if service_is_running "$service_name"; then
        echo "Already running: $service_name (port $port)" >&2
      else
        if ! start_service "$service_name" "$profile_dir" --port "$port" --hostname "$hostname"; then
          echo "Failed to start: $service_name" >&2
          for sn in "${started_names[@]+"${started_names[@]}"}"; do
            stop_service "$sn" >/dev/null 2>&1 || true
          done
          return 1
        fi
        started_names+=("$service_name")
      fi
    else
      port="$(next_batch_port "$port_start")"
      service_name="$(build_folder_service_name "$resolved_prefix" "$profile_name")"

      if ! start_service "$service_name" "$profile_dir" --port "$port" --hostname "$hostname"; then
        echo "Failed to start: $service_name" >&2
        for sn in "${started_names[@]+"${started_names[@]}"}"; do
          stop_service "$sn" >/dev/null 2>&1 || true
        done
        return 1
      fi
      append_state_entry "$service_name" "$profile_dir" "$port"
      started_names+=("$service_name")
    fi
  done

  save_batch_state "$BATCH_FOLDER_RESOLVED" "$resolved_prefix" "$port_start" "$hostname"
  echo "Batch start completed for ${#BATCH_PROFILE_DIRS[@]} profiles." >&2
}

stop_folder_services() {
  local folder_input="${1:-$DEFAULT_PROFILES_DIR}"
  local service_prefix=""
  local resolved_prefix index state_loaded=0

  shift 2>/dev/null || true

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix)
        service_prefix="$2"; shift 2 ;;
      *)
        shift ;;
    esac
  done

  collect_folder_profiles "$folder_input" || return 1
  resolved_prefix="$(build_folder_service_prefix "$BATCH_FOLDER_RESOLVED" "$service_prefix")"

  if load_batch_state "$BATCH_FOLDER_RESOLVED" "$resolved_prefix"; then
    state_loaded=1
  fi

  if [ "$state_loaded" -eq 1 ]; then
    for index in "${!STATE_SERVICE_NAMES[@]}"; do
      stop_service "${STATE_SERVICE_NAMES[$index]}" || true
    done
    save_batch_state "$BATCH_FOLDER_RESOLVED" "$resolved_prefix" "${STATE_PORT_START:-$DEFAULT_PORT_START}" "${STATE_HOSTNAME:-0.0.0.0}"
    return 0
  fi

  echo "No batch state found for: $BATCH_FOLDER_RESOLVED" >&2
}

restart_folder_services() {
  local folder_input="${1:-$DEFAULT_PROFILES_DIR}"
  stop_folder_services "$@"
  start_folder_services "$@"
}

status_folder_services() {
  local folder_input="${1:-$DEFAULT_PROFILES_DIR}"
  local service_prefix=""
  local resolved_prefix index state_loaded=0

  shift 2>/dev/null || true

  while [ "$#" -gt 0 ]; do
    case "$1" in
      --prefix)
        service_prefix="$2"; shift 2 ;;
      *)
        shift ;;
    esac
  done

  collect_folder_profiles "$folder_input" || return 1
  resolved_prefix="$(build_folder_service_prefix "$BATCH_FOLDER_RESOLVED" "$service_prefix")"

  if load_batch_state "$BATCH_FOLDER_RESOLVED" "$resolved_prefix"; then
    state_loaded=1
  fi

  for index in "${!BATCH_PROFILE_DIRS[@]}"; do
    local profile_dir="${BATCH_PROFILE_DIRS[$index]}"
    local profile_name="${BATCH_PROFILE_NAMES[$index]}"

    if [ "$state_loaded" -eq 1 ] && find_state_index_by_profile_dir "$profile_dir"; then
      print_service_status "${STATE_SERVICE_NAMES[$STATE_MATCH_INDEX]}"
    else
      local sn
      sn="$(build_folder_service_name "$resolved_prefix" "$profile_name")"
      if service_has_metadata "$sn"; then
        print_service_status "$sn"
      else
        echo "$sn: not started (profile=$profile_name)"
      fi
    fi
  done
}

sync_folder_profiles() {
  local folder_input="${1:-$DEFAULT_PROFILES_DIR}"
  local profile_dir

  shift 2>/dev/null || true

  collect_folder_profiles "$folder_input" || return 1

  for profile_dir in "${BATCH_PROFILE_DIRS[@]}"; do
    sync_profile "$profile_dir" || true
  done
}

list_services() {
  if [ ! -d "$SERVICE_BASE_DIR" ]; then
    echo "No services found."
    return
  fi

  local found=0 root

  for root in "$SERVICE_BASE_DIR"/*; do
    if [ ! -d "$root" ]; then
      continue
    fi
    found=1
    print_service_status "$(basename "$root")"
  done

  if [ "$found" -eq 0 ]; then
    echo "No services found."
  fi
}

show_logs() {
  local service_name="$1"
  local lines="${2:-50}"

  ensure_service_name "$service_name"
  load_service_meta "$service_name"

  if [ ! -f "$LOG_FILE" ]; then
    echo "Log file not found for: $service_name" >&2
    return 1
  fi

  tail -n "$lines" "$LOG_FILE"
}

if [ "$#" -lt 1 ]; then
  usage
fi

COMMAND="$1"
shift || true

case "$COMMAND" in
  start)
    if [ "$#" -lt 1 ]; then usage; fi
    local_profile_name="$1"; shift
    profile_dir="$(resolve_profile_dir_for_name "$local_profile_name")"
    start_service "$local_profile_name" "$profile_dir" "$@"
    ;;
  start-folder)
    start_folder_services "$@"
    ;;
  stop)
    if [ "$#" -ne 1 ]; then usage; fi
    stop_service "$1"
    ;;
  stop-folder)
    stop_folder_services "$@"
    ;;
  restart)
    if [ "$#" -ne 1 ]; then usage; fi
    stop_service "$1" || true
    local_profile_name="$1"
    if service_has_metadata "$local_profile_name"; then
      load_service_meta "$local_profile_name"
      start_service "$local_profile_name" "$PROFILE_DIR" --port "$PORT" --hostname "${HOSTNAME:-0.0.0.0}"
    else
      echo "Cannot restart: no saved metadata for $local_profile_name" >&2
      exit 1
    fi
    ;;
  restart-folder)
    restart_folder_services "$@"
    ;;
  status)
    if [ "$#" -eq 0 ]; then
      list_services
    else
      ensure_service_name "$1"
      print_service_status "$1"
    fi
    ;;
  status-folder)
    status_folder_services "$@"
    ;;
  sync)
    if [ "$#" -lt 1 ]; then usage; fi
    profile_dir="$(resolve_profile_dir_for_name "$1")"
    sync_profile "$profile_dir"
    ;;
  sync-folder)
    sync_folder_profiles "$@"
    ;;
  list)
    list_services
    ;;
  logs)
    if [ "$#" -lt 1 ] || [ "$#" -gt 2 ]; then usage; fi
    show_logs "$@"
    ;;
  *)
    usage
    ;;
esac
