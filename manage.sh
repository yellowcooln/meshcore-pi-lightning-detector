#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SERVICE_NAME="meshcore-lightning.service"
SERVICE_PATH="/etc/systemd/system/${SERVICE_NAME}"
VENV_PATH="${SCRIPT_DIR}/.venv"
CONFIG_PATH="${SCRIPT_DIR}/config.toml"
EXAMPLE_CONFIG_PATH="${SCRIPT_DIR}/config.example.toml"
RUN_USER="${SUDO_USER:-$USER}"
RUN_GROUP="$(id -gn "${RUN_USER}")"
SUPPLEMENTARY_GROUPS_LINE=""
PYTHON_BIN="${PYTHON_BIN:-python3}"

if getent group i2c >/dev/null 2>&1; then
  SUPPLEMENTARY_GROUPS_LINE="SupplementaryGroups=i2c"
fi

usage() {
  cat <<'EOF'
Usage: ./manage.sh <command>

Commands:
  install    Create/update venv, install app, install systemd service, enable service
  start      Start the systemd service
  stop       Stop the systemd service
  restart    Restart the systemd service
  status     Show systemd service status
  test       Run a one-shot MeshCore verify/probe using the project virtualenv
  logs       Tail service logs
  uninstall  Stop and remove the systemd service
EOF
}

stage() {
  echo
  echo "==> $1"
}

info() {
  echo "  - $1"
}

run_as_owner() {
  if [[ "${EUID}" -eq 0 && "${RUN_USER}" != "root" ]]; then
    sudo -u "${RUN_USER}" -H "$@"
  else
    "$@"
  fi
}

repair_generated_ownership() {
  if [[ "${EUID}" -ne 0 || "${RUN_USER}" == "root" ]]; then
    return
  fi

  stage "Repairing ownership of generated project files"

  local paths=()
  if [[ -d "${VENV_PATH}" ]]; then
    paths+=("${VENV_PATH}")
  fi
  if [[ -f "${CONFIG_PATH}" ]]; then
    paths+=("${CONFIG_PATH}")
  fi

  while IFS= read -r path; do
    paths+=("${path}")
  done < <(find "${SCRIPT_DIR}" -maxdepth 1 -type d -name '*.egg-info' 2>/dev/null)

  while IFS= read -r path; do
    paths+=("${path}")
  done < <(find "${SCRIPT_DIR}" -maxdepth 2 -type d -name '__pycache__' 2>/dev/null)

  if [[ "${#paths[@]}" -eq 0 ]]; then
    info "No generated files needed ownership repair"
    return
  fi

  info "Ensuring generated files are owned by ${RUN_USER}:${RUN_GROUP}"
  sudo chown -R "${RUN_USER}:${RUN_GROUP}" "${paths[@]}"
}

need_cmd() {
  if ! command -v "$1" >/dev/null 2>&1; then
    echo "Missing required command: $1" >&2
    exit 1
  fi
}

ensure_root_tools() {
  need_cmd sudo
  sudo -n true >/dev/null 2>&1 || {
    echo "This script requires sudo access." >&2
    exit 1
  }
}

ensure_python_env() {
  stage "Preparing Python environment"
  need_cmd "${PYTHON_BIN}"
  if [[ ! -d "${VENV_PATH}" ]]; then
    info "Creating virtual environment at ${VENV_PATH}"
    run_as_owner "${PYTHON_BIN}" -m venv "${VENV_PATH}"
  else
    info "Reusing existing virtual environment at ${VENV_PATH}"
  fi
  info "Upgrading pip"
  run_as_owner "${VENV_PATH}/bin/pip" install --upgrade pip
  info "Installing project into the virtual environment"
  run_as_owner "${VENV_PATH}/bin/pip" install -e "${SCRIPT_DIR}"
}

ensure_config() {
  stage "Checking project configuration"
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    info "Creating ${CONFIG_PATH} from ${EXAMPLE_CONFIG_PATH}"
    run_as_owner cp "${EXAMPLE_CONFIG_PATH}" "${CONFIG_PATH}"
    echo "Created ${CONFIG_PATH} from example. Edit it before starting the service."
  else
    info "Using existing config at ${CONFIG_PATH}"
  fi
}

ensure_runtime_ready() {
  if [[ ! -x "${VENV_PATH}/bin/meshcore-lightning" ]]; then
    echo "The project virtual environment is not ready at ${VENV_PATH}." >&2
    echo "Run ./manage.sh install first." >&2
    exit 1
  fi

  if [[ ! -f "${CONFIG_PATH}" ]]; then
    echo "Missing ${CONFIG_PATH}." >&2
    echo "Run ./manage.sh install first." >&2
    exit 1
  fi
}

read_config_value() {
  local file="$1"
  local section="$2"
  local key="$3"
  "${PYTHON_BIN}" - "$file" "$section" "$key" <<'PY'
import sys, tomllib

path, section, key = sys.argv[1:4]
with open(path, "rb") as handle:
    data = tomllib.load(handle)
value = data[section][key]
print(value)
PY
}

prompt_with_default() {
  local prompt_text="$1"
  local default_value="$2"
  local result=""
  read -r -p "${prompt_text} [${default_value}]: " result
  if [[ -z "${result}" ]]; then
    result="${default_value}"
  fi
  printf '%s' "${result}"
}

prompt_optional_with_default() {
  local prompt_text="$1"
  local default_value="$2"
  local result=""
  if [[ -n "${default_value}" ]]; then
    read -r -p "${prompt_text} [${default_value}]: " result
    if [[ -z "${result}" ]]; then
      result="${default_value}"
    fi
  else
    read -r -p "${prompt_text} (leave blank for hashtag/public-style rooms): " result
  fi
  printf '%s' "${result}"
}

collect_meshcore_settings() {
  stage "Collecting MeshCore connection settings"

  local source_path="${CONFIG_PATH}"
  if [[ ! -f "${source_path}" ]]; then
    source_path="${EXAMPLE_CONFIG_PATH}"
  fi

  local default_host default_port default_channel_name default_channel_key
  default_host="$(read_config_value "${source_path}" meshcore host)"
  default_port="$(read_config_value "${source_path}" meshcore port)"
  default_channel_name="$(read_config_value "${source_path}" meshcore channel_name)"
  default_channel_key="$(read_config_value "${source_path}" meshcore channel_key)"

  MESHCORE_HOST="$(prompt_with_default "MeshCore TCP host or IP" "${default_host}")"
  MESHCORE_PORT="$(prompt_with_default "MeshCore TCP port" "${default_port}")"
  MESHCORE_CHANNEL_NAME="$(prompt_with_default "Channel name" "${default_channel_name}")"
  MESHCORE_CHANNEL_KEY="$(prompt_optional_with_default "Channel key" "${default_channel_key}")"

  if [[ ! "${MESHCORE_PORT}" =~ ^[0-9]+$ ]] || [[ "${MESHCORE_PORT}" -lt 1 || "${MESHCORE_PORT}" -gt 65535 ]]; then
    echo "Invalid port: ${MESHCORE_PORT}" >&2
    exit 1
  fi

  if [[ -n "${MESHCORE_CHANNEL_KEY}" ]] && [[ ! "${MESHCORE_CHANNEL_KEY}" =~ ^[0-9A-Fa-f]{32}$ ]]; then
    echo "Channel key must be exactly 32 hex characters when provided." >&2
    exit 1
  fi

  if [[ ! "${MESHCORE_CHANNEL_NAME}" =~ ^# ]] && [[ -z "${MESHCORE_CHANNEL_KEY}" ]]; then
    echo "Private channels require a channel key, or use a name that starts with #." >&2
    exit 1
  fi

  info "Host: ${MESHCORE_HOST}"
  info "Port: ${MESHCORE_PORT}"
  info "Channel: ${MESHCORE_CHANNEL_NAME}"
  if [[ -n "${MESHCORE_CHANNEL_KEY}" ]]; then
    info "Channel key: provided"
  else
    info "Channel key: derived from channel name"
  fi
}

write_meshcore_config() {
  stage "Writing MeshCore settings to config.toml"
  info "Updating [meshcore] settings in ${CONFIG_PATH}"
  run_as_owner env \
    CONFIG_PATH="${CONFIG_PATH}" \
    EXAMPLE_CONFIG_PATH="${EXAMPLE_CONFIG_PATH}" \
    MESHCORE_HOST="${MESHCORE_HOST}" \
    MESHCORE_PORT="${MESHCORE_PORT}" \
    MESHCORE_CHANNEL_NAME="${MESHCORE_CHANNEL_NAME}" \
    MESHCORE_CHANNEL_KEY="${MESHCORE_CHANNEL_KEY}" \
    "${PYTHON_BIN}" - <<'PY'
import os
import tomllib
from pathlib import Path

config_path = Path(os.environ["CONFIG_PATH"])
example_path = Path(os.environ["EXAMPLE_CONFIG_PATH"])
source_path = config_path if config_path.exists() else example_path

with source_path.open("rb") as handle:
    data = tomllib.load(handle)

data["meshcore"]["host"] = os.environ["MESHCORE_HOST"]
data["meshcore"]["port"] = int(os.environ["MESHCORE_PORT"])
data["meshcore"]["channel_name"] = os.environ["MESHCORE_CHANNEL_NAME"]
data["meshcore"]["channel_key"] = os.environ["MESHCORE_CHANNEL_KEY"].upper()

def dump_bool(value: bool) -> str:
    return "true" if value else "false"

lines = [
    "[meshcore]",
    f'host = "{data["meshcore"]["host"]}"',
    f'port = {data["meshcore"]["port"]}',
    f'channel_name = "{data["meshcore"]["channel_name"]}"',
    f'channel_key = "{data["meshcore"]["channel_key"]}"',
    f'channel_slot = {data["meshcore"]["channel_slot"]}',
    f'always_configure_channel = {dump_bool(data["meshcore"]["always_configure_channel"])}',
    f'connect_timeout_seconds = {data["meshcore"]["connect_timeout_seconds"]}',
    "",
    "[sensor]",
    f'i2c_bus = {data["sensor"]["i2c_bus"]}',
    f'i2c_address = "{data["sensor"]["i2c_address"]}"',
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
    f'message_prefix = "{data["alerts"]["message_prefix"]}"',
    "",
    "[logging]",
    f'level = "{data["logging"]["level"]}"',
    "",
]

config_path.write_text("\n".join(lines), encoding="utf-8")
PY
}

report_i2c_status() {
  stage "Checking Raspberry Pi I2C status"
  if [[ -e /dev/i2c-1 ]]; then
    echo "Detected /dev/i2c-1. Raspberry Pi I2C appears to be enabled."
  else
    echo "I2C bus /dev/i2c-1 was not found."
    echo "If this is a Raspberry Pi, enable I2C with: sudo raspi-config"
    echo "Then reboot and re-run this script."
  fi
}

install_service_file() {
  stage "Installing systemd service"
  ensure_root_tools
  info "Writing ${SERVICE_PATH}"
  sudo tee "${SERVICE_PATH}" >/dev/null <<EOF
[Unit]
Description=MeshCore Lightning App
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=${RUN_USER}
Group=${RUN_GROUP}
${SUPPLEMENTARY_GROUPS_LINE}
WorkingDirectory=${SCRIPT_DIR}
Environment=PYTHONUNBUFFERED=1
ExecStart=${VENV_PATH}/bin/meshcore-lightning --config ${CONFIG_PATH} monitor
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF
  info "Reloading systemd daemon"
  sudo systemctl daemon-reload
  info "Enabling ${SERVICE_NAME}"
  sudo systemctl enable "${SERVICE_NAME}"
}

install_app() {
  stage "Installing MeshCore Pi Lightning Detector"
  repair_generated_ownership
  ensure_python_env
  ensure_config
  collect_meshcore_settings
  write_meshcore_config
  install_service_file
  report_i2c_status
  echo
  echo "Install complete."
  echo "Next steps:"
  echo "  1. If /dev/i2c-1 is missing, enable I2C on the Pi and reboot"
  echo "  2. Run: ./manage.sh start"
}

start_service() {
  stage "Starting service"
  ensure_root_tools
  info "Starting ${SERVICE_NAME}"
  sudo systemctl start "${SERVICE_NAME}"
  sudo systemctl --no-pager --full status "${SERVICE_NAME}"
}

stop_service() {
  stage "Stopping service"
  ensure_root_tools
  info "Stopping ${SERVICE_NAME}"
  sudo systemctl stop "${SERVICE_NAME}"
}

restart_service() {
  stage "Restarting service"
  ensure_root_tools
  info "Restarting ${SERVICE_NAME}"
  sudo systemctl restart "${SERVICE_NAME}"
  sudo systemctl --no-pager --full status "${SERVICE_NAME}"
}

status_service() {
  stage "Service status"
  ensure_root_tools
  sudo systemctl --no-pager --full status "${SERVICE_NAME}"
}

logs_service() {
  stage "Tailing service logs"
  ensure_root_tools
  sudo journalctl -u "${SERVICE_NAME}" -n 100 -f
}

test_runtime() {
  stage "Running one-shot MeshCore probe"
  ensure_runtime_ready
  info "Using ${CONFIG_PATH}"
  info "Running verify-channel --send-probe from the project virtual environment"
  run_as_owner "${VENV_PATH}/bin/meshcore-lightning" --config "${CONFIG_PATH}" verify-channel --send-probe
}

uninstall_service() {
  stage "Removing systemd service"
  ensure_root_tools
  if sudo systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    info "Stopping ${SERVICE_NAME} if it is running"
    sudo systemctl stop "${SERVICE_NAME}" || true
    info "Disabling ${SERVICE_NAME}"
    sudo systemctl disable "${SERVICE_NAME}" || true
  fi
  if [[ -f "${SERVICE_PATH}" ]]; then
    info "Removing ${SERVICE_PATH}"
    sudo rm -f "${SERVICE_PATH}"
    info "Reloading systemd daemon"
    sudo systemctl daemon-reload
  fi
  echo "Removed ${SERVICE_NAME}."
  echo "Virtual environment and config were left in place at ${SCRIPT_DIR}."
}

main() {
  if [[ $# -eq 0 ]]; then
    usage
    exit 0
  fi

  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  case "$1" in
    -h|--help|help)
      usage
      ;;
    install)
      install_app
      ;;
    start)
      start_service
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
    test)
      test_runtime
      ;;
    logs)
      logs_service
      ;;
    uninstall)
      uninstall_service
      ;;
    *)
      usage
      exit 1
      ;;
  esac
}

main "$@"
