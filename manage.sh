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
  need_cmd python3
  if [[ ! -d "${VENV_PATH}" ]]; then
    python3 -m venv "${VENV_PATH}"
  fi
  "${VENV_PATH}/bin/pip" install --upgrade pip
  "${VENV_PATH}/bin/pip" install -e "${SCRIPT_DIR}"
}

ensure_config() {
  if [[ ! -f "${CONFIG_PATH}" ]]; then
    cp "${EXAMPLE_CONFIG_PATH}" "${CONFIG_PATH}"
    echo "Created ${CONFIG_PATH} from example. Edit it before starting the service."
  fi
}

install_service_file() {
  ensure_root_tools
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
  sudo systemctl daemon-reload
  sudo systemctl enable "${SERVICE_NAME}"
}

install_app() {
  ensure_python_env
  ensure_config
  install_service_file
  echo
  echo "Install complete."
  echo "Next steps:"
  echo "  1. Edit ${CONFIG_PATH}"
  echo "  2. Enable I2C on the Pi if you have not already"
  echo "  3. Run: ./manage.sh start"
}

start_service() {
  ensure_root_tools
  sudo systemctl start "${SERVICE_NAME}"
  sudo systemctl --no-pager --full status "${SERVICE_NAME}"
}

stop_service() {
  ensure_root_tools
  sudo systemctl stop "${SERVICE_NAME}"
}

restart_service() {
  ensure_root_tools
  sudo systemctl restart "${SERVICE_NAME}"
  sudo systemctl --no-pager --full status "${SERVICE_NAME}"
}

status_service() {
  ensure_root_tools
  sudo systemctl --no-pager --full status "${SERVICE_NAME}"
}

logs_service() {
  ensure_root_tools
  sudo journalctl -u "${SERVICE_NAME}" -n 100 -f
}

uninstall_service() {
  ensure_root_tools
  if sudo systemctl list-unit-files | grep -q "^${SERVICE_NAME}"; then
    sudo systemctl stop "${SERVICE_NAME}" || true
    sudo systemctl disable "${SERVICE_NAME}" || true
  fi
  if [[ -f "${SERVICE_PATH}" ]]; then
    sudo rm -f "${SERVICE_PATH}"
    sudo systemctl daemon-reload
  fi
  echo "Removed ${SERVICE_NAME}."
  echo "Virtual environment and config were left in place at ${SCRIPT_DIR}."
}

main() {
  if [[ $# -ne 1 ]]; then
    usage
    exit 1
  fi

  case "$1" in
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
