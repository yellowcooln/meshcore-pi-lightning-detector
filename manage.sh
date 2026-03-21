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
  need_cmd python3
  if [[ ! -d "${VENV_PATH}" ]]; then
    info "Creating virtual environment at ${VENV_PATH}"
    python3 -m venv "${VENV_PATH}"
  else
    info "Reusing existing virtual environment at ${VENV_PATH}"
  fi
  info "Upgrading pip"
  "${VENV_PATH}/bin/pip" install --upgrade pip
  info "Installing project into the virtual environment"
  "${VENV_PATH}/bin/pip" install -e "${SCRIPT_DIR}"
}

ensure_config() {
  stage "Checking project configuration"
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    info "Creating ${CONFIG_PATH} from ${EXAMPLE_CONFIG_PATH}"
    cp "${EXAMPLE_CONFIG_PATH}" "${CONFIG_PATH}"
    echo "Created ${CONFIG_PATH} from example. Edit it before starting the service."
  else
    info "Using existing config at ${CONFIG_PATH}"
  fi
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
  ensure_python_env
  ensure_config
  install_service_file
  report_i2c_status
  echo
  echo "Install complete."
  echo "Next steps:"
  echo "  1. Edit ${CONFIG_PATH}"
  echo "  2. If /dev/i2c-1 is missing, enable I2C on the Pi and reboot"
  echo "  3. Run: ./manage.sh start"
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
