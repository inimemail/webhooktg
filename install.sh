#!/usr/bin/env bash

set -o pipefail

APP_NAME="TG Notify Manager"
BASE_DIR="${TG_NOTIFY_HOME:-$HOME/.tg-notify}"
CONFIG_FILE="${BASE_DIR}/config.env"
APP_DIR="${BASE_DIR}/app"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
INDEX_FILE="${APP_DIR}/index.js"
RUNTIME_FILE="${APP_DIR}/.runtime"
INSTALL_MARK="# tg-notify"
DEFAULT_PORT="3000"
DEFAULT_WORK_DIR="/opt/api-webhook"
DEFAULT_UPDATE_URL=""

red() { printf '\033[31m%s\033[0m\n' "$*"; }
green() { printf '\033[32m%s\033[0m\n' "$*"; }
yellow() { printf '\033[33m%s\033[0m\n' "$*"; }
blue() { printf '\033[36m%s\033[0m\n' "$*"; }

info() { blue "信息: $*"; }
ok() { green "成功: $*"; }
warn() { yellow "提示: $*"; }
err() { red "错误: $*"; }

pause_enter() {
    local _
    read -r -p "按回车继续..." _
}

have_docker_compose() {
    docker compose version >/dev/null 2>&1 || docker-compose version >/dev/null 2>&1
}

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        printf 'docker compose'
    else
        printf 'docker-compose'
    fi
}

ensure_base() {
    mkdir -p "${BASE_DIR}" "${APP_DIR}"
    touch "${CONFIG_FILE}"
}

clean_value() {
    local value="$1"
    printf '%s' "${value}" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

read_default() {
    local prompt="$1"
    local default_value="$2"
    local value
    read -r -p "${prompt} [${default_value}]: " value
    value="$(clean_value "${value}")"
    [[ -n "${value}" ]] || value="${default_value}"
    printf '%s\n' "${value}"
}

read_required() {
    local prompt="$1"
    local value
    while true; do
        read -r -p "${prompt}: " value
        value="$(clean_value "${value}")"
        [[ -n "${value}" ]] && { printf '%s\n' "${value}"; return 0; }
        warn "不能为空。"
    done
}

confirm() {
    local prompt="$1"
    local ans
    read -r -p "${prompt} [y/N]: " ans
    [[ "${ans}" =~ ^[Yy]([Ee][Ss])?$ ]]
}

load_config() {
    ensure_base
    if [[ -f "${CONFIG_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${CONFIG_FILE}" 2>/dev/null || true
    fi
    SECRET_KEY="${SECRET_KEY:-}"
    TG_BOT_TOKEN="${TG_BOT_TOKEN:-}"
    TG_CHAT_ID="${TG_CHAT_ID:-}"
    PORT="${PORT:-${DEFAULT_PORT}}"
    WORK_DIR="${WORK_DIR:-${DEFAULT_WORK_DIR}}"
    UPDATE_URL="${UPDATE_URL:-${DEFAULT_UPDATE_URL}}"
}

save_config() {
    ensure_base
    cat > "${CONFIG_FILE}" <<EOF
SECRET_KEY='${SECRET_KEY//\'/\'\"\'\"\' }'
TG_BOT_TOKEN='${TG_BOT_TOKEN//\'/\'\"\'\"\' }'
TG_CHAT_ID='${TG_CHAT_ID//\'/\'\"\'\"\' }'
PORT='${PORT//\'/\'\"\'\"\' }'
WORK_DIR='${WORK_DIR//\'/\'\"\'\"\' }'
UPDATE_URL='${UPDATE_URL//\'/\'\"\'\"\' }'
EOF
}

install_runtime_files() {
    ensure_base
    cat > "${INDEX_FILE}" <<'EOF'
const express = require('express');
const crypto = require('crypto');

const app = express();
app.use(express.json({ limit: '1mb' }));

const { SECRET_KEY, TG_BOT_TOKEN, TG_CHAT_ID, PORT } = process.env;

function safeText(value) {
    if (value === null || value === undefined) return '';
    if (typeof value === 'string') return value;
    return JSON.stringify(value, null, 2);
}

app.post('/webhook/notify', async (req, res) => {
    try {
        const payload = req.body || {};
        const receivedSign = req.headers['x-signature'] || req.headers['sign'];

        if (receivedSign && SECRET_KEY) {
            const signString = JSON.stringify(payload) + SECRET_KEY;
            const calculatedSign = crypto.createHash('md5').update(signString).digest('hex');
            if (calculatedSign !== receivedSign) {
                return res.status(401).json({ msg: 'Invalid Signature' });
            }
        }

        const message = `API 通知\n\n事件: ${safeText(payload.event_type || payload.type || '状态更新')}\n详情:\n${safeText(payload)}`;

        const tgRes = await fetch(`https://api.telegram.org/bot${TG_BOT_TOKEN}/sendMessage`, {
            method: 'POST',
            headers: { 'Content-Type': 'application/json' },
            body: JSON.stringify({
                chat_id: TG_CHAT_ID,
                text: message,
                parse_mode: 'HTML'
            })
        });

        if (!tgRes.ok) {
            throw new Error(`Telegram API error: ${tgRes.status}`);
        }

        res.status(200).json({ msg: 'Success' });
    } catch (error) {
        console.error('webhook error:', error);
        res.status(500).json({ msg: 'Internal Server Error' });
    }
});

app.get('/health', (_req, res) => res.json({ ok: true }));

app.listen(PORT, () => console.log(`Webhook receiver running on port ${PORT}`));
EOF

    cat > "${COMPOSE_FILE}" <<EOF
services:
  webhook-bot:
    image: node:20-alpine
    container_name: api-webhook-bot
    working_dir: /app
    volumes:
      - ./index.js:/app/index.js
    command: sh -c "npm install express && node index.js"
    ports:
      - "${PORT}:${PORT}"
    environment:
      - SECRET_KEY=${SECRET_KEY}
      - TG_BOT_TOKEN=${TG_BOT_TOKEN}
      - TG_CHAT_ID=${TG_CHAT_ID}
      - PORT=${PORT}
    restart: always
EOF
}

compose_up() {
    local cmd
    cmd="$(compose_cmd)"
    (cd "${APP_DIR}" && ${cmd} up -d)
}

compose_down() {
    local cmd
    cmd="$(compose_cmd)"
    (cd "${APP_DIR}" && ${cmd} down)
}

compose_restart() {
    local cmd
    cmd="$(compose_cmd)"
    (cd "${APP_DIR}" && ${cmd} restart)
}

show_status() {
    load_config
    printf '\n%s\n' "========== ${APP_NAME} =========="
    printf '配置目录: %s\n' "${BASE_DIR}"
    printf '工作目录: %s\n' "${WORK_DIR}"
    printf '端口: %s\n' "${PORT}"
    printf 'Webhook: http://127.0.0.1:%s/webhook/notify\n' "${PORT}"
    printf '健康检查: http://127.0.0.1:%s/health\n' "${PORT}"
    if [[ -f "${CONFIG_FILE}" ]]; then
        printf '配置文件: %s\n' "${CONFIG_FILE}"
    fi
    if [[ -f "${RUNTIME_FILE}" ]]; then
        printf '状态: 已安装\n'
    else
        printf '状态: 未安装\n'
    fi
}

edit_config() {
    load_config
    echo
    echo "逐项填写，直接回车可保留当前值。"
    SECRET_KEY="$(read_default "通信密钥 SECRET_KEY" "${SECRET_KEY:-secret-$(date +%s)}")"
    TG_BOT_TOKEN="$(read_required "Telegram Bot Token")"
    TG_CHAT_ID="$(read_required "Telegram Chat ID")"
    PORT="$(read_default "端口" "${PORT}")"
    WORK_DIR="$(read_default "工作目录" "${WORK_DIR}")"
    UPDATE_URL="$(read_default "更新地址(留空则使用内置脚本)" "${UPDATE_URL}")"
    save_config
    ok "配置已保存。"
}

write_runtime_flag() {
    date '+%Y-%m-%d %H:%M:%S' > "${RUNTIME_FILE}"
}

do_install() {
    load_config
    if [[ -z "${TG_BOT_TOKEN}" || -z "${TG_CHAT_ID}" ]]; then
        warn "先补全配置。"
        edit_config
        load_config
    fi
    install_runtime_files
    write_runtime_flag
    compose_up
    ok "已部署并启动。"
    printf '地址: http://<你的服务器IP>:%s/webhook/notify\n' "${PORT}"
    printf '健康检查: http://<你的服务器IP>:%s/health\n' "${PORT}"
}

do_restart() {
    load_config
    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        warn "还没安装。"
        return 0
    fi
    compose_restart
    ok "已重启。"
}

do_stop() {
    load_config
    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        warn "还没安装。"
        return 0
    fi
    compose_down
    ok "已停止。"
}

do_update() {
    load_config
    if [[ -n "${UPDATE_URL}" ]]; then
        warn "当前脚本更新地址已自定义，这里先保留配置，不自动远程拉取。"
    fi
    install_runtime_files
    write_runtime_flag
    compose_up
    ok "已按当前配置重新生成并启动。"
}

do_uninstall() {
    load_config
    echo
    echo "将删除:"
    echo "1. 容器和编排文件"
    echo "2. 配置目录: ${BASE_DIR}"
    echo "3. 运行标记"
    echo
    if ! confirm "确认继续卸载"; then
        warn "已取消。"
        return 0
    fi
    do_stop >/dev/null 2>&1 || true
    rm -f "${COMPOSE_FILE}" "${INDEX_FILE}" "${RUNTIME_FILE}"
    rm -rf "${APP_DIR}"
    rm -f "${CONFIG_FILE}"
    if [[ -d "${BASE_DIR}" ]]; then
        rmdir "${BASE_DIR}" 2>/dev/null || true
    fi
    ok "已卸载。"
}

show_logs() {
    load_config
    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        warn "还没安装。"
        return 0
    fi
    local cmd
    cmd="$(compose_cmd)"
    (cd "${APP_DIR}" && ${cmd} logs -f --tail=100 webhook-bot)
}

menu_fill_hint() {
    echo "所有关键项都可以填。回车保留当前值。"
}

main_menu() {
    while true; do
        load_config
        echo
        echo "========== ${APP_NAME} =========="
        echo "1. 安装/生成"
        echo "2. 修改配置"
        echo "3. 更新"
        echo "4. 重启"
        echo "5. 停止"
        echo "6. 查看状态"
        echo "7. 查看日志"
        echo "8. 卸载删除"
        echo "0. 退出"
        echo
        local choice
        read -r -p "请选择 [0-8]: " choice
        case "${choice}" in
            1) menu_fill_hint; do_install; pause_enter ;;
            2) menu_fill_hint; edit_config; pause_enter ;;
            3) do_update; pause_enter ;;
            4) do_restart; pause_enter ;;
            5) do_stop; pause_enter ;;
            6) show_status; pause_enter ;;
            7) show_logs; pause_enter ;;
            8) do_uninstall; pause_enter ;;
            0) exit 0 ;;
            *) warn "无效选项。" ;;
        esac
    done
}

usage() {
    cat <<EOF
用法:
  bash tg-notify.sh
  bash tg-notify.sh install
  bash tg-notify.sh edit
  bash tg-notify.sh update
  bash tg-notify.sh restart
  bash tg-notify.sh stop
  bash tg-notify.sh status
  bash tg-notify.sh logs
  bash tg-notify.sh uninstall
EOF
}

main() {
    ensure_base
    case "${1:-}" in
        install) do_install ;;
        edit|config) edit_config ;;
        update) do_update ;;
        restart) do_restart ;;
        stop) do_stop ;;
        status) show_status ;;
        logs) show_logs ;;
        uninstall|remove|purge) do_uninstall ;;
        help|-h|--help) usage ;;
        "") main_menu ;;
        *) usage; exit 1 ;;
    esac
}

main "$@"
