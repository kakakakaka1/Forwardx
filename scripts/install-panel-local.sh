#!/bin/bash
set -euo pipefail

ACTION="${1:-install}"
APP_DIR="${FORWARDX_PANEL_DIR:-/opt/forwardx-panel}"
SERVICE_NAME="${FORWARDX_SERVICE_NAME:-forwardx-panel}"
REPO_URL="${FORWARDX_REPO_URL:-https://github.com/poouo/Forwardx.git}"
PORT="${PORT:-3000}"

require_root() {
  if [ "$(id -u)" != "0" ]; then
    echo "[错误] 请使用 root 权限运行"
    exit 1
  fi
}

confirm_yes() {
  local prompt="$1"
  local answer=""

  if [ -r /dev/tty ] && [ -w /dev/tty ]; then
    printf "%s" "$prompt" > /dev/tty
    IFS= read -r answer < /dev/tty || answer=""
  else
    echo "[信息] 非交互环境，默认选择 N：$prompt"
  fi

  case "$answer" in
    y|Y|yes|YES) return 0 ;;
    *) return 1 ;;
  esac
}

latest_tag() {
  git -C "$APP_DIR" tag --sort=-v:refname | head -1 || true
}

install_deps() {
  if command -v apt-get >/dev/null 2>&1; then
    apt-get update -qq
    apt-get install -y -qq curl git ca-certificates build-essential python3 openssl >/dev/null
    if ! command -v node >/dev/null 2>&1; then
      curl -fsSL https://deb.nodesource.com/setup_22.x | bash -
      apt-get install -y -qq nodejs >/dev/null
    fi
  elif command -v dnf >/dev/null 2>&1; then
    dnf install -y -q curl git ca-certificates gcc gcc-c++ make python3 openssl nodejs npm
  elif command -v yum >/dev/null 2>&1; then
    yum install -y -q curl git ca-certificates gcc gcc-c++ make python3 openssl nodejs npm
  elif command -v apk >/dev/null 2>&1; then
    apk add --no-cache curl git ca-certificates build-base python3 openssl nodejs npm
  fi

  command -v node >/dev/null 2>&1 || { echo "[错误] Node.js 安装失败，请先安装 Node.js 22+"; exit 1; }
  corepack enable >/dev/null 2>&1 || npm install -g pnpm@10
  corepack prepare pnpm@10 --activate >/dev/null 2>&1 || npm install -g pnpm@10
}

sync_source() {
  local target="${FORWARDX_TARGET_VERSION:-}"
  if [ -d "$APP_DIR/.git" ]; then
    git -C "$APP_DIR" fetch --tags origin
  else
    rm -rf "$APP_DIR"
    git clone "$REPO_URL" "$APP_DIR"
    git -C "$APP_DIR" fetch --tags origin
  fi

  if [ -z "$target" ]; then
    target="$(latest_tag)"
  fi
  if [ -n "$target" ]; then
    git -C "$APP_DIR" checkout -f "$target"
  else
    git -C "$APP_DIR" checkout -f main
  fi
}

build_panel() {
  cd "$APP_DIR"
  pnpm install --prod=false
  pnpm build
}

write_env() {
  local jwt_secret="${JWT_SECRET:-}"
  if [ -z "$jwt_secret" ]; then
    jwt_secret="$(openssl rand -hex 32 2>/dev/null || date +%s%N | sha256sum | awk '{print $1}')"
  fi

  mkdir -p "$APP_DIR/data"
  cat > "$APP_DIR/.env" <<EOF
NODE_ENV=production
PORT=$PORT
DATABASE_CONFIG_PATH=$APP_DIR/data/database.json
SQLITE_PATH=$APP_DIR/data/forwardx.db
MYSQL_CONFIG_PATH=$APP_DIR/data/mysql.json
JWT_SECRET=$jwt_secret
FORWARDX_UPGRADE_COMMAND="/bin/bash $APP_DIR/scripts/install-panel-local.sh upgrade"
EOF
}

write_service() {
  cat > "/etc/systemd/system/$SERVICE_NAME.service" <<EOF
[Unit]
Description=ForwardX Panel
After=network.target

[Service]
Type=simple
WorkingDirectory=$APP_DIR
EnvironmentFile=$APP_DIR/.env
ExecStart=$(command -v node) dist/index.js
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

  systemctl daemon-reload
  systemctl enable "$SERVICE_NAME"
}

install_panel() {
  require_root
  install_deps
  sync_source
  build_panel
  write_env
  write_service
  systemctl restart "$SERVICE_NAME"
  echo "[完成] ForwardX 面板已启动：http://服务器IP:$PORT"
  echo "[信息] 首次打开面板后请配置 MySQL；如果连接旧数据库，将自动复用原有管理员和数据。"
}

upgrade_panel() {
  require_root
  install_deps
  sync_source
  build_panel
  write_env
  write_service
  systemctl restart "$SERVICE_NAME"
  echo "[完成] ForwardX 面板已升级并重启"
}

uninstall_panel() {
  require_root
  systemctl stop "$SERVICE_NAME" 2>/dev/null || true
  systemctl disable "$SERVICE_NAME" 2>/dev/null || true
  rm -f "/etc/systemd/system/$SERVICE_NAME.service"
  systemctl daemon-reload

  if confirm_yes "是否删除面板程序目录 $APP_DIR ? [y/N] "; then
    rm -rf "$APP_DIR"
    echo "[完成] 已删除 $APP_DIR"
  else
    echo "[完成] 已卸载服务，保留 $APP_DIR"
  fi
}

case "$ACTION" in
  install) install_panel ;;
  upgrade|update) upgrade_panel ;;
  uninstall|remove) uninstall_panel ;;
  *)
    echo "用法: $0 install|upgrade|uninstall"
    exit 1
    ;;
esac
