#!/bin/sh
set -eu

SCRIPT_DIR=$(CDPATH= cd -- "$(dirname -- "$0")" && pwd)
CONFIG_PATH="${SCRIPT_DIR}/config.toml"
EXAMPLE_CONFIG_PATH="${SCRIPT_DIR}/config.example.toml"
RUNTIME_DIR="${SCRIPT_DIR}/.buildroot-runtime"
TARGET_PATH="${RUNTIME_DIR}/site-packages"
LAUNCHER_PATH="${RUNTIME_DIR}/meshcore-lightning-runner.sh"
PID_FILE="${RUNTIME_DIR}/meshcore-lightning.pid"
LOG_FILE="${RUNTIME_DIR}/meshcore-lightning.log"
INIT_SCRIPT_PATH="/etc/init.d/S99meshcore-lightning"
PYTHON_BIN="${PYTHON_BIN:-python3}"

usage() {
  cat <<'EOF'
Usage: ./buildroot-manage.sh <command>

Commands:
  install              Prepare Python runtime, prompt for MeshCore settings, and write config
  upgrade              Pull latest git changes, refresh the app install, and restart the monitor
  setup                Reconfigure alert message settings in config.toml
  run                  Run the monitor in the foreground
  start                Start the background monitor; use "start logs" to tail logs immediately
  stop                 Stop the background monitor
  restart              Restart the background monitor
  status               Show background monitor status
  logs                 Tail the background monitor log
  test                 Verify the configured channel can be loaded without sending a message
  send                 Send a custom message to the configured channel
  install-init-script  Install a BusyBox-style init script at /etc/init.d/S99meshcore-lightning
  uninstall-init-script Remove the BusyBox-style init script
EOF
}

stage() {
  printf '\n==> %s\n' "$1"
}

info() {
  printf '  - %s\n' "$1"
}

warn() {
  printf '  - %s\n' "$1"
}

fail() {
  printf '%s\n' "$1" >&2
  exit 1
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    fail "Missing required command: $1"
  fi
}

ensure_python_version() {
  need_cmd "${PYTHON_BIN}"
  "${PYTHON_BIN}" - <<'PY'
import sys
raise SystemExit(0 if sys.version_info >= (3, 10) else 1)
PY
}

ensure_directories() {
  mkdir -p "${RUNTIME_DIR}"
}

as_root() {
  if [ "$(id -u)" -eq 0 ]; then
    "$@"
    return
  fi
  if command -v sudo >/dev/null 2>&1; then
    sudo "$@"
    return
  fi
  fail "This command requires root. Re-run as root or use sudo."
}

read_config_value_with_fallback() {
  file_path="$1"
  fallback_path="$2"
  section_name="$3"
  key_name="$4"
  "${PYTHON_BIN}" - "$file_path" "$fallback_path" "$section_name" "$key_name" <<'PY'
import sys

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

path, fallback_path, section, key = sys.argv[1:5]

with open(fallback_path, "rb") as handle:
    fallback = tomllib.load(handle)

with open(path, "rb") as handle:
    data = tomllib.load(handle)

value = data.get(section, {}).get(key, fallback[section][key])
print(value)
PY
}

prompt_with_default() {
  prompt_text="$1"
  default_value="$2"
  result=""
  printf '%s [%s]: ' "$prompt_text" "$default_value"
  IFS= read -r result
  if [ -z "$result" ]; then
    result="$default_value"
  fi
  printf '%s' "$result"
}

prompt_optional_with_default() {
  prompt_text="$1"
  default_value="$2"
  result=""
  if [ -n "$default_value" ]; then
    printf '%s [%s]: ' "$prompt_text" "$default_value"
    IFS= read -r result
    if [ -z "$result" ]; then
      result="$default_value"
    fi
  else
    printf '%s (leave blank for hashtag/public-style rooms): ' "$prompt_text"
    IFS= read -r result
  fi
  printf '%s' "$result"
}

prompt_choice_with_default() {
  prompt_text="$1"
  default_value="$2"
  result=""
  printf '%s [%s]: ' "$prompt_text" "$default_value"
  IFS= read -r result
  if [ -z "$result" ]; then
    result="$default_value"
  fi
  printf '%s' "$result"
}

ensure_config() {
  stage "Checking project configuration"
  if [ ! -f "${CONFIG_PATH}" ]; then
    info "Creating ${CONFIG_PATH} from ${EXAMPLE_CONFIG_PATH}"
    cp "${EXAMPLE_CONFIG_PATH}" "${CONFIG_PATH}"
  else
    info "Using existing config at ${CONFIG_PATH}"
  fi
}

collect_meshcore_settings() {
  stage "Collecting MeshCore connection settings"

  source_path="${CONFIG_PATH}"
  if [ ! -f "${source_path}" ]; then
    source_path="${EXAMPLE_CONFIG_PATH}"
  fi

  default_host=$(read_config_value_with_fallback "${source_path}" "${EXAMPLE_CONFIG_PATH}" meshcore host)
  default_port=$(read_config_value_with_fallback "${source_path}" "${EXAMPLE_CONFIG_PATH}" meshcore port)
  default_channel_name=$(read_config_value_with_fallback "${source_path}" "${EXAMPLE_CONFIG_PATH}" meshcore channel_name)
  default_channel_key=$(read_config_value_with_fallback "${source_path}" "${EXAMPLE_CONFIG_PATH}" meshcore channel_key)

  MESHCORE_HOST=$(prompt_with_default "MeshCore TCP host or IP" "${default_host}")
  MESHCORE_PORT=$(prompt_with_default "MeshCore TCP port" "${default_port}")
  MESHCORE_CHANNEL_NAME=$(prompt_with_default "Channel name" "${default_channel_name}")
  MESHCORE_CHANNEL_KEY=$(prompt_optional_with_default "Channel key" "${default_channel_key}")

  case "${MESHCORE_PORT}" in
    ''|*[!0-9]*)
      fail "Invalid port: ${MESHCORE_PORT}"
      ;;
  esac

  if [ "${MESHCORE_PORT}" -lt 1 ] || [ "${MESHCORE_PORT}" -gt 65535 ]; then
    fail "Invalid port: ${MESHCORE_PORT}"
  fi

  if [ -n "${MESHCORE_CHANNEL_KEY}" ]; then
    if ! printf '%s' "${MESHCORE_CHANNEL_KEY}" | grep -Eq '^[0-9A-Fa-f]{32}$'; then
      fail "Channel key must be exactly 32 hex characters when provided."
    fi
  fi

  case "${MESHCORE_CHANNEL_NAME}" in
    \#*)
      :
      ;;
    *)
      if [ -z "${MESHCORE_CHANNEL_KEY}" ]; then
        fail "Private channels require a channel key, or use a name that starts with #."
      fi
      ;;
  esac

  info "Host: ${MESHCORE_HOST}"
  info "Port: ${MESHCORE_PORT}"
  info "Channel: ${MESHCORE_CHANNEL_NAME}"
  if [ -n "${MESHCORE_CHANNEL_KEY}" ]; then
    info "Channel key: provided"
  else
    info "Channel key: derived from channel name"
  fi
}

write_meshcore_config() {
  stage "Writing MeshCore settings to config.toml"
  info "Updating [meshcore] settings in ${CONFIG_PATH}"
  CONFIG_PATH="${CONFIG_PATH}" \
    EXAMPLE_CONFIG_PATH="${EXAMPLE_CONFIG_PATH}" \
    MESHCORE_HOST="${MESHCORE_HOST}" \
    MESHCORE_PORT="${MESHCORE_PORT}" \
    MESHCORE_CHANNEL_NAME="${MESHCORE_CHANNEL_NAME}" \
    MESHCORE_CHANNEL_KEY="${MESHCORE_CHANNEL_KEY}" \
    "${PYTHON_BIN}" - <<'PY'
import os
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

config_path = Path(os.environ["CONFIG_PATH"])
example_path = Path(os.environ["EXAMPLE_CONFIG_PATH"])
source_path = config_path if config_path.exists() else example_path

with example_path.open("rb") as handle:
    data = tomllib.load(handle)

if source_path != example_path:
    with source_path.open("rb") as handle:
        current = tomllib.load(handle)
    for section, values in current.items():
        if isinstance(values, dict) and isinstance(data.get(section), dict):
            data[section].update(values)
        else:
            data[section] = values

data["meshcore"]["host"] = os.environ["MESHCORE_HOST"]
data["meshcore"]["port"] = int(os.environ["MESHCORE_PORT"])
data["meshcore"]["channel_name"] = os.environ["MESHCORE_CHANNEL_NAME"]
data["meshcore"]["channel_key"] = os.environ["MESHCORE_CHANNEL_KEY"].upper()

def dump_bool(value: bool) -> str:
    return "true" if value else "false"

def dump_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'

lines = [
    "[meshcore]",
    f'host = {dump_string(data["meshcore"]["host"])}',
    f'port = {data["meshcore"]["port"]}',
    f'channel_name = {dump_string(data["meshcore"]["channel_name"])}',
    f'channel_key = {dump_string(data["meshcore"]["channel_key"])}',
    f'channel_slot = {data["meshcore"]["channel_slot"]}',
    f'always_configure_channel = {dump_bool(data["meshcore"]["always_configure_channel"])}',
    f'connect_timeout_seconds = {data["meshcore"]["connect_timeout_seconds"]}',
    "",
    "[sensor]",
    f'i2c_bus = {data["sensor"]["i2c_bus"]}',
    f'i2c_address = {dump_string(data["sensor"]["i2c_address"])}',
    f'irq_gpio = {dump_string(str(data["sensor"].get("irq_gpio", "")))}',
    f'indoor = {dump_bool(data["sensor"]["indoor"])}',
    f'noise_floor = {data["sensor"]["noise_floor"]}',
    f'watchdog_threshold = {data["sensor"]["watchdog_threshold"]}',
    f'spike_rejection = {data["sensor"]["spike_rejection"]}',
    f'minimum_lightnings = {data["sensor"]["minimum_lightnings"]}',
    f'mask_disturbers = {dump_bool(data["sensor"]["mask_disturbers"])}',
    f'reset_defaults_on_start = {dump_bool(data["sensor"]["reset_defaults_on_start"])}',
    f'calibrate_on_start = {dump_bool(data["sensor"]["calibrate_on_start"])}',
    f'clear_statistics_on_start = {dump_bool(data["sensor"]["clear_statistics_on_start"])}',
    f'poll_interval_seconds = {data["sensor"]["poll_interval_seconds"]}',
    "",
    "[alerts]",
    f'cooldown_seconds = {data["alerts"]["cooldown_seconds"]}',
    f'send_noise_messages = {dump_bool(data["alerts"]["send_noise_messages"])}',
    f'send_disturber_messages = {dump_bool(data["alerts"]["send_disturber_messages"])}',
    f'message_prefix = {dump_string(data["alerts"]["message_prefix"])}',
    f'distance_unit = {dump_string(data["alerts"]["distance_unit"])}',
    f'time_format = {dump_string(data["alerts"]["time_format"])}',
    f'lightning_message_template = {dump_string(data["alerts"]["lightning_message_template"])}',
    "",
    "[logging]",
    f'level = {dump_string(data["logging"]["level"])}',
    "",
]

config_path.write_text("\n".join(lines), encoding="utf-8")
PY
}

collect_alert_message_settings() {
  stage "Collecting alert message settings"

  source_path="${CONFIG_PATH}"
  if [ ! -f "${source_path}" ]; then
    source_path="${EXAMPLE_CONFIG_PATH}"
  fi

  default_lightning_template=$(read_config_value_with_fallback "${source_path}" "${EXAMPLE_CONFIG_PATH}" alerts lightning_message_template)
  default_distance_unit=$(read_config_value_with_fallback "${source_path}" "${EXAMPLE_CONFIG_PATH}" alerts distance_unit)
  default_time_format=$(read_config_value_with_fallback "${source_path}" "${EXAMPLE_CONFIG_PATH}" alerts time_format)

  info "Choose a lightning message style:"
  printf '    1) Keep current setting\n'
  printf '    2) Detailed: Lightning detected at {time} | Distance={distance} | Energy={energy}\n'
  printf '    3) Time only: Lightning detected at {time}\n'
  printf '    4) Time and date: Lightning detected at {time} on {date}\n'
  printf '    5) Minimal: Lightning detected\n'
  printf '    6) Custom template\n'

  template_choice=$(prompt_choice_with_default "Select an option" "1")

  case "${template_choice}" in
    1) LIGHTNING_MESSAGE_TEMPLATE="${default_lightning_template}" ;;
    2) LIGHTNING_MESSAGE_TEMPLATE="Lightning detected at {time} | Distance={distance} | Energy={energy}" ;;
    3) LIGHTNING_MESSAGE_TEMPLATE="Lightning detected at {time}" ;;
    4) LIGHTNING_MESSAGE_TEMPLATE="Lightning detected at {time} on {date}" ;;
    5) LIGHTNING_MESSAGE_TEMPLATE="Lightning detected" ;;
    6)
      info "Available placeholders: {prefix}, {distance}, {energy}, {interrupt_code}, {kind}, {time}, {time24}, {time12}, {date}"
      LIGHTNING_MESSAGE_TEMPLATE=$(prompt_with_default "Custom lightning message template" "${default_lightning_template}")
      ;;
    *)
      fail "Invalid setup choice: ${template_choice}"
      ;;
  esac

  info "Choose a distance unit:"
  printf '    1) Keep current setting (%s)\n' "${default_distance_unit}"
  printf '    2) Kilometers (km)\n'
  printf '    3) Miles (mi)\n'

  distance_choice=$(prompt_choice_with_default "Select an option" "1")

  case "${distance_choice}" in
    1) DISTANCE_UNIT="${default_distance_unit}" ;;
    2) DISTANCE_UNIT="km" ;;
    3) DISTANCE_UNIT="mi" ;;
    *)
      fail "Invalid distance unit choice: ${distance_choice}"
      ;;
  esac

  info "Choose a time format for {time}:"
  printf '    1) Keep current setting (%s)\n' "${default_time_format}"
  printf '    2) 24-hour time (HH:MM:SS)\n'
  printf '    3) 12-hour time (HH:MM:SS AM/PM)\n'

  time_choice=$(prompt_choice_with_default "Select an option" "1")

  case "${time_choice}" in
    1) TIME_FORMAT="${default_time_format}" ;;
    2) TIME_FORMAT="24h" ;;
    3) TIME_FORMAT="12h" ;;
    *)
      fail "Invalid time format choice: ${time_choice}"
      ;;
  esac

  info "Distance unit: ${DISTANCE_UNIT}"
  info "Time format: ${TIME_FORMAT}"
  info "Lightning message template: ${LIGHTNING_MESSAGE_TEMPLATE}"
}

write_alert_message_config() {
  stage "Writing alert message settings to config.toml"
  info "Updating [alerts] settings in ${CONFIG_PATH}"
  CONFIG_PATH="${CONFIG_PATH}" \
    EXAMPLE_CONFIG_PATH="${EXAMPLE_CONFIG_PATH}" \
    DISTANCE_UNIT="${DISTANCE_UNIT}" \
    TIME_FORMAT="${TIME_FORMAT}" \
    LIGHTNING_MESSAGE_TEMPLATE="${LIGHTNING_MESSAGE_TEMPLATE}" \
    "${PYTHON_BIN}" - <<'PY'
import os
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

config_path = Path(os.environ["CONFIG_PATH"])
example_path = Path(os.environ["EXAMPLE_CONFIG_PATH"])
source_path = config_path if config_path.exists() else example_path

with example_path.open("rb") as handle:
    data = tomllib.load(handle)

if source_path != example_path:
    with source_path.open("rb") as handle:
        current = tomllib.load(handle)
    for section, values in current.items():
        if isinstance(values, dict) and isinstance(data.get(section), dict):
            data[section].update(values)
        else:
            data[section] = values

data["alerts"]["lightning_message_template"] = os.environ["LIGHTNING_MESSAGE_TEMPLATE"]
data["alerts"]["distance_unit"] = os.environ["DISTANCE_UNIT"]
data["alerts"]["time_format"] = os.environ["TIME_FORMAT"]

def dump_bool(value: bool) -> str:
    return "true" if value else "false"

def dump_string(value: str) -> str:
    escaped = value.replace("\\", "\\\\").replace('"', '\\"')
    return f'"{escaped}"'

lines = [
    "[meshcore]",
    f'host = {dump_string(data["meshcore"]["host"])}',
    f'port = {data["meshcore"]["port"]}',
    f'channel_name = {dump_string(data["meshcore"]["channel_name"])}',
    f'channel_key = {dump_string(data["meshcore"]["channel_key"])}',
    f'channel_slot = {data["meshcore"]["channel_slot"]}',
    f'always_configure_channel = {dump_bool(data["meshcore"]["always_configure_channel"])}',
    f'connect_timeout_seconds = {data["meshcore"]["connect_timeout_seconds"]}',
    "",
    "[sensor]",
    f'i2c_bus = {data["sensor"]["i2c_bus"]}',
    f'i2c_address = {dump_string(data["sensor"]["i2c_address"])}',
    f'irq_gpio = {dump_string(str(data["sensor"].get("irq_gpio", "")))}',
    f'indoor = {dump_bool(data["sensor"]["indoor"])}',
    f'noise_floor = {data["sensor"]["noise_floor"]}',
    f'watchdog_threshold = {data["sensor"]["watchdog_threshold"]}',
    f'spike_rejection = {data["sensor"]["spike_rejection"]}',
    f'minimum_lightnings = {data["sensor"]["minimum_lightnings"]}',
    f'mask_disturbers = {dump_bool(data["sensor"]["mask_disturbers"])}',
    f'reset_defaults_on_start = {dump_bool(data["sensor"]["reset_defaults_on_start"])}',
    f'calibrate_on_start = {dump_bool(data["sensor"]["calibrate_on_start"])}',
    f'clear_statistics_on_start = {dump_bool(data["sensor"]["clear_statistics_on_start"])}',
    f'poll_interval_seconds = {data["sensor"]["poll_interval_seconds"]}',
    "",
    "[alerts]",
    f'cooldown_seconds = {data["alerts"]["cooldown_seconds"]}',
    f'send_noise_messages = {dump_bool(data["alerts"]["send_noise_messages"])}',
    f'send_disturber_messages = {dump_bool(data["alerts"]["send_disturber_messages"])}',
    f'message_prefix = {dump_string(data["alerts"]["message_prefix"])}',
    f'distance_unit = {dump_string(data["alerts"]["distance_unit"])}',
    f'time_format = {dump_string(data["alerts"]["time_format"])}',
    f'lightning_message_template = {dump_string(data["alerts"]["lightning_message_template"])}',
    "",
    "[logging]",
    f'level = {dump_string(data["logging"]["level"])}',
    "",
]

config_path.write_text("\n".join(lines), encoding="utf-8")
PY
}

install_target_runtime() {
  if ! "${PYTHON_BIN}" -m pip --version >/dev/null 2>&1; then
    fail "python3 -m pip is required when python3 -m venv is unavailable."
  fi
  info "python -m venv is unavailable; using repo-local target install at ${TARGET_PATH}"
  rm -rf "${TARGET_PATH}"
  mkdir -p "${TARGET_PATH}"
  "${PYTHON_BIN}" -m pip install --upgrade pip
  "${PYTHON_BIN}" -m pip install --target "${TARGET_PATH}" "${SCRIPT_DIR}"
}

write_runtime_launcher() {
  stage "Writing runtime launcher"
  info "Writing ${LAUNCHER_PATH}"

  if [ -x "${VENV_PATH}/bin/meshcore-lightning" ]; then
    cat > "${LAUNCHER_PATH}" <<EOF
#!/bin/sh
set -eu
exec "${VENV_PATH}/bin/meshcore-lightning" --config "${CONFIG_PATH}" "\$@"
EOF
  else
    cat > "${LAUNCHER_PATH}" <<EOF
#!/bin/sh
set -eu
PYTHONPATH="${TARGET_PATH}\${PYTHONPATH:+:\$PYTHONPATH}"
export PYTHONPATH
cd "${SCRIPT_DIR}"
exec "${PYTHON_BIN}" -m app.main --config "${CONFIG_PATH}" "\$@"
EOF
  fi

  chmod +x "${LAUNCHER_PATH}"
}

ensure_python_env() {
  stage "Preparing Python environment"
  ensure_python_version
  ensure_directories

  if "${PYTHON_BIN}" -m venv --help >/dev/null 2>&1; then
    info "Using virtual environment at ${VENV_PATH}"
    if [ ! -d "${VENV_PATH}" ]; then
      if ! "${PYTHON_BIN}" -m venv "${VENV_PATH}"; then
        warn "python -m venv failed; falling back to repo-local target install"
        rm -rf "${VENV_PATH}"
        install_target_runtime
        write_runtime_launcher
        return
      fi
    fi
    if [ ! -x "${VENV_PATH}/bin/pip" ]; then
      warn "virtual environment pip is unavailable; falling back to repo-local target install"
      rm -rf "${VENV_PATH}"
      install_target_runtime
      write_runtime_launcher
      return
    fi
    info "Upgrading pip"
    "${VENV_PATH}/bin/pip" install --upgrade pip
    info "Installing project into the virtual environment"
    "${VENV_PATH}/bin/pip" install -e "${SCRIPT_DIR}"
  else
    install_target_runtime
  fi

  write_runtime_launcher
}

ensure_runtime_ready() {
  if [ ! -x "${LAUNCHER_PATH}" ]; then
    fail "The Buildroot runtime is not ready. Run ./buildroot-manage.sh install first."
  fi
  if [ ! -f "${CONFIG_PATH}" ]; then
    fail "Missing ${CONFIG_PATH}. Run ./buildroot-manage.sh install first."
  fi
}

is_running() {
  if [ ! -f "${PID_FILE}" ]; then
    return 1
  fi
  pid=$(cat "${PID_FILE}" 2>/dev/null || true)
  if [ -z "${pid}" ]; then
    rm -f "${PID_FILE}"
    return 1
  fi
  if kill -0 "${pid}" 2>/dev/null; then
    return 0
  fi
  rm -f "${PID_FILE}"
  return 1
}

render_default_lightning_message() {
  CONFIG_PATH="${CONFIG_PATH}" \
    EXAMPLE_CONFIG_PATH="${EXAMPLE_CONFIG_PATH}" \
    "${PYTHON_BIN}" - <<'PY'
import os
from datetime import datetime
from pathlib import Path

try:
    import tomllib
except ModuleNotFoundError:
    import tomli as tomllib

config_path = Path(os.environ["CONFIG_PATH"])
example_path = Path(os.environ["EXAMPLE_CONFIG_PATH"])

with example_path.open("rb") as handle:
    data = tomllib.load(handle)

if config_path.exists():
    with config_path.open("rb") as handle:
        current = tomllib.load(handle)
    for section, values in current.items():
        if isinstance(values, dict) and isinstance(data.get(section), dict):
            data[section].update(values)
        else:
            data[section] = values

template = data["alerts"]["lightning_message_template"]
prefix = data["alerts"]["message_prefix"]
distance_unit = str(data["alerts"].get("distance_unit", "km")).strip().lower()
time_format = str(data["alerts"].get("time_format", "24h")).strip().lower()
sample_date = datetime.now().astimezone().strftime("%Y-%m-%d")
sample_time24 = datetime.now().astimezone().strftime("%H:%M:%S")
sample_time12 = datetime.now().astimezone().strftime("%I:%M:%S %p")
sample_time = sample_time12 if time_format == "12h" else sample_time24

class SafeFormatDict(dict):
    def __missing__(self, key):
        return "{" + key + "}"

message = template.format_map(
    SafeFormatDict(
        prefix=prefix,
        distance="12 km" if distance_unit == "km" else "7.5 mi",
        energy="12345",
        interrupt_code="0x08",
        kind="lightning",
        time=sample_time,
        time24=sample_time24,
        time12=sample_time12,
        date=sample_date,
    )
)

print(message)
PY
}

ensure_git_repo_ready() {
  need_cmd git
  if ! git -C "${SCRIPT_DIR}" rev-parse --is-inside-work-tree >/dev/null 2>&1; then
    fail "${SCRIPT_DIR} is not a git repository."
  fi
}

ensure_clean_git_worktree() {
  ensure_git_repo_ready
  if [ -n "$(git -C "${SCRIPT_DIR}" status --porcelain)" ]; then
    fail "Local git changes detected in ${SCRIPT_DIR}. Commit, stash, or discard them before running upgrade."
  fi
}

pull_latest_code() {
  stage "Pulling latest repository changes"
  ensure_clean_git_worktree
  current_branch=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref HEAD)
  info "Using git branch ${current_branch}"
  if upstream_branch=$(git -C "${SCRIPT_DIR}" rev-parse --abbrev-ref --symbolic-full-name '@{upstream}' 2>/dev/null); then
    info "Pulling latest changes from ${upstream_branch}"
    git -C "${SCRIPT_DIR}" pull --ff-only
  else
    info "Pulling latest changes from origin/${current_branch}"
    git -C "${SCRIPT_DIR}" pull --ff-only origin "${current_branch}"
  fi
}

install_app() {
  stage "Installing MeshCore Pi Lightning Detector For Buildroot"
  ensure_config
  collect_meshcore_settings
  write_meshcore_config
  ensure_python_env
  printf '\nInstall complete.\n'
  printf 'Next steps:\n'
  printf '  1. Run: ./buildroot-manage.sh start\n'
  printf '  2. Run: ./buildroot-manage.sh test\n'
}

upgrade_app() {
  stage "Upgrading MeshCore Pi Lightning Detector For Buildroot"
  if [ ! -f "${CONFIG_PATH}" ]; then
    fail "Missing ${CONFIG_PATH}. Run ./buildroot-manage.sh install first."
  fi
  pull_latest_code
  ensure_python_env
  restart_service
  printf '\nUpgrade complete.\n'
}

setup_alerts() {
  stage "Configuring alert message settings"
  ensure_config
  collect_alert_message_settings
  write_alert_message_config
  printf '\nSetup complete.\n'
  printf 'Next steps:\n'
  printf '  1. Run: ./buildroot-manage.sh test\n'
  printf '  2. Run: ./buildroot-manage.sh send\n'
}

run_monitor_foreground() {
  stage "Running foreground monitor"
  ensure_runtime_ready
  exec "${LAUNCHER_PATH}" monitor
}

start_service() {
  stage "Starting background monitor"
  ensure_runtime_ready
  need_cmd nohup
  ensure_directories
  if is_running; then
    info "Monitor is already running with PID $(cat "${PID_FILE}")"
    return
  fi
  : > "${LOG_FILE}"
  info "Writing logs to ${LOG_FILE}"
  nohup "${LAUNCHER_PATH}" monitor >>"${LOG_FILE}" 2>&1 &
  echo "$!" > "${PID_FILE}"
  sleep 1
  if is_running; then
    info "Monitor started with PID $(cat "${PID_FILE}")"
  else
    fail "Monitor failed to start. Check ${LOG_FILE}."
  fi
}

start_and_logs_service() {
  start_service
  logs_service
}

stop_service() {
  stage "Stopping background monitor"
  if ! is_running; then
    info "Monitor is not running"
    return
  fi
  pid=$(cat "${PID_FILE}")
  info "Stopping PID ${pid}"
  kill "${pid}" 2>/dev/null || true
  count=0
  while kill -0 "${pid}" 2>/dev/null; do
    count=$((count + 1))
    if [ "${count}" -ge 10 ]; then
      info "Sending SIGKILL to PID ${pid}"
      kill -9 "${pid}" 2>/dev/null || true
      break
    fi
    sleep 1
  done
  rm -f "${PID_FILE}"
}

restart_service() {
  stage "Restarting background monitor"
  if is_running; then
    pid=$(cat "${PID_FILE}")
    info "Stopping PID ${pid}"
    kill "${pid}" 2>/dev/null || true
    sleep 1
    rm -f "${PID_FILE}"
  fi
  start_service
}

status_service() {
  stage "Background monitor status"
  if is_running; then
    info "Running with PID $(cat "${PID_FILE}")"
    info "Log file: ${LOG_FILE}"
  else
    info "Monitor is not running"
  fi
}

logs_service() {
  stage "Tailing background monitor log"
  ensure_directories
  : > "${LOG_FILE}"
  tail -n 100 -f "${LOG_FILE}"
}

test_runtime() {
  stage "Verifying configured channel"
  ensure_runtime_ready
  info "Using ${CONFIG_PATH}"
  info "Running verify-channel without sending a message"
  "${LAUNCHER_PATH}" verify-channel
}

send_custom_message() {
  stage "Sending custom channel message"
  ensure_runtime_ready
  if [ "$#" -ge 1 ]; then
    message="$*"
  else
    message=$(render_default_lightning_message)
  fi
  info "Using ${CONFIG_PATH}"
  info "Sending message to the configured channel"
  "${LAUNCHER_PATH}" send-test --message "${message}"
}

install_init_script() {
  stage "Installing BusyBox init script"
  as_root sh -c "cat > '${INIT_SCRIPT_PATH}' <<'EOF'
#!/bin/sh
case \"\$1\" in
  start)
    exec sh '${SCRIPT_DIR}/buildroot-manage.sh' start
    ;;
  stop)
    exec sh '${SCRIPT_DIR}/buildroot-manage.sh' stop
    ;;
  restart)
    exec sh '${SCRIPT_DIR}/buildroot-manage.sh' restart
    ;;
  status)
    exec sh '${SCRIPT_DIR}/buildroot-manage.sh' status
    ;;
  *)
    echo \"Usage: \$0 {start|stop|restart|status}\"
    exit 1
    ;;
esac
EOF"
  as_root chmod +x "${INIT_SCRIPT_PATH}"
  info "Installed ${INIT_SCRIPT_PATH}"
}

uninstall_init_script() {
  stage "Removing BusyBox init script"
  if [ -f "${INIT_SCRIPT_PATH}" ]; then
    as_root rm -f "${INIT_SCRIPT_PATH}"
    info "Removed ${INIT_SCRIPT_PATH}"
  else
    info "Init script is not installed"
  fi
}

main() {
  if [ "$#" -eq 0 ]; then
    usage
    exit 0
  fi

  case "$1" in
    -h|--help|help)
      usage
      ;;
    install)
      install_app
      ;;
    upgrade)
      upgrade_app
      ;;
    setup)
      setup_alerts
      ;;
    run)
      run_monitor_foreground
      ;;
    start)
      if [ "${2:-}" = "logs" ]; then
        start_and_logs_service
      else
        start_service
      fi
      ;;
    stop)
      stop_service
      ;;
    restart)
      restart_service
      ;;
    status)
      status_service
      ;;
    logs)
      logs_service
      ;;
    test)
      test_runtime
      ;;
    send)
      shift
      send_custom_message "$@"
      ;;
    install-init-script)
      install_init_script
      ;;
    uninstall-init-script)
      uninstall_init_script
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
