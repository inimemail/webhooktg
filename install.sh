#!/usr/bin/env bash

set -o pipefail

APP_NAME="TG Notify Manager"
BASE_DIR="${TG_NOTIFY_HOME:-$HOME/.tg-notify}"
DATA_DIR="${BASE_DIR}/data"
APP_DIR="${BASE_DIR}/app"
SETTINGS_FILE="${BASE_DIR}/settings.env"
BOTS_DB="${DATA_DIR}/bots.tsv"
NOTIFIERS_DB="${DATA_DIR}/notifiers.tsv"
COMPOSE_FILE="${APP_DIR}/docker-compose.yml"
INDEX_FILE="${APP_DIR}/index.js"
RUNTIME_FLAG="${BASE_DIR}/.installed"
DEFAULT_PORT="3000"
DEFAULT_UPDATE_URL=""
DEFAULT_INSTALL_URL="https://raw.githubusercontent.com/inimemail/webhooktg/main/install.sh"

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

ensure_base() {
    mkdir -p "${DATA_DIR}" "${APP_DIR}"
    touch "${BOTS_DB}" "${NOTIFIERS_DB}"
}

trim() {
    printf '%s' "$1" | tr -d '\r' | sed 's/^[[:space:]]*//; s/[[:space:]]*$//'
}

escape_sq() {
    printf '%s' "$1" | sed "s/'/'\"'\"'/g"
}

read_default() {
    local prompt="$1"
    local default_value="$2"
    local value
    read -r -p "${prompt} [${default_value}]: " value
    value="$(trim "${value}")"
    [[ -n "${value}" ]] || value="${default_value}"
    printf '%s\n' "${value}"
}

read_required() {
    local prompt="$1"
    local value
    while true; do
        read -r -p "${prompt}: " value
        value="$(trim "${value}")"
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

row_count() {
    local file="$1"
    local count=0
    local first
    while IFS=$'\t' read -r first _; do
        [[ -n "${first}" ]] && count=$((count + 1))
    done < "${file}"
    printf '%s\n' "${count}"
}

get_id_by_seq() {
    local file="$1"
    local wanted_seq="$2"
    local seq=1
    local id
    while IFS=$'\t' read -r id _; do
        [[ -n "${id}" ]] || continue
        if [[ "${seq}" -eq "${wanted_seq}" ]]; then
            printf '%s\n' "${id}"
            return 0
        fi
        seq=$((seq + 1))
    done < "${file}"
    return 1
}

next_id() {
    local file="$1"
    local max=0
    local id
    while IFS=$'\t' read -r id _; do
        [[ "${id}" =~ ^[0-9]+$ ]] || continue
        (( id > max )) && max="${id}"
    done < "${file}"
    printf '%s\n' "$((max + 1))"
}

status_label() {
    case "$1" in
        yes) printf '启用' ;;
        *) printf '停用' ;;
    esac
}

short_token() {
    local token="$1"
    [[ -n "${token}" ]] || { printf '-'; return 0; }
    if [[ "${#token}" -le 12 ]]; then
        printf '%s' "${token}"
    else
        printf '%s...%s' "${token:0:6}" "${token: -4}"
    fi
}

load_settings() {
    ensure_base
    SECRET_KEY=""
    PORT="${DEFAULT_PORT}"
    UPDATE_URL="${DEFAULT_UPDATE_URL}"
    INSTALL_URL="${DEFAULT_INSTALL_URL}"
    WORK_DIR="${BASE_DIR}"
    if [[ -f "${SETTINGS_FILE}" ]]; then
        # shellcheck disable=SC1090
        source "${SETTINGS_FILE}" 2>/dev/null || true
    fi
    SECRET_KEY="${SECRET_KEY:-}"
    PORT="${PORT:-${DEFAULT_PORT}}"
    UPDATE_URL="${UPDATE_URL:-${DEFAULT_UPDATE_URL}}"
    INSTALL_URL="${INSTALL_URL:-${DEFAULT_INSTALL_URL}}"
    WORK_DIR="${WORK_DIR:-${BASE_DIR}}"
}

save_settings() {
    ensure_base
    {
        printf "SECRET_KEY='%s'\n" "$(escape_sq "${SECRET_KEY}")"
        printf "PORT='%s'\n" "$(escape_sq "${PORT}")"
        printf "UPDATE_URL='%s'\n" "$(escape_sq "${UPDATE_URL}")"
        printf "INSTALL_URL='%s'\n" "$(escape_sq "${INSTALL_URL}")"
        printf "WORK_DIR='%s'\n" "$(escape_sq "${WORK_DIR}")"
    } > "${SETTINGS_FILE}"
}

detect_server_ip() {
    local candidate=""
    if [[ -n "${TG_NOTIFY_PUBLIC_IP:-}" ]]; then
        printf '%s\n' "${TG_NOTIFY_PUBLIC_IP}"
        return 0
    fi

    if command -v hostname >/dev/null 2>&1; then
        candidate="$(hostname -I 2>/dev/null | tr ' ' '\n' | grep -Ev '^(127\.|0\.0\.0\.0$|::1$)' | head -n 1 || true)"
        [[ -n "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
    fi

    if command -v ip >/dev/null 2>&1; then
        candidate="$(ip -4 route get 1.1.1.1 2>/dev/null | awk '{for (i = 1; i <= NF; i++) if ($i == "src") { print $(i + 1); exit }}' || true)"
        [[ -n "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
        candidate="$(ip -4 addr show scope global 2>/dev/null | awk '/inet /{print $2}' | cut -d/ -f1 | grep -Ev '^(127\.|0\.0\.0\.0$)' | head -n 1 || true)"
        [[ -n "${candidate}" ]] && { printf '%s\n' "${candidate}"; return 0; }
    fi

    printf '127.0.0.1\n'
}

service_base_url() {
    local ip
    ip="$(detect_server_ip)"
    printf 'http://%s:%s' "${ip}" "${PORT}"
}

service_running() {
    if [[ ! -f "${COMPOSE_FILE}" ]]; then
        return 1
    fi
    local cmd
    cmd="$(compose_cmd)"
    (cd "${APP_DIR}" && ${cmd} ps -q tg-notify 2>/dev/null | grep -q .)
}

write_runtime() {
    ensure_base
    cat > "${INDEX_FILE}" <<'EOF'
const fs = require('fs');
const path = require('path');
const http = require('http');
const crypto = require('crypto');

const dataDir = process.env.TG_NOTIFY_DATA_DIR || '/srv/data';
const settingsPath = process.env.TG_NOTIFY_SETTINGS_FILE || '/srv/settings.env';
const port = Number(process.env.PORT || 3000);

function readText(file) {
  try { return fs.readFileSync(file, 'utf8'); } catch { return ''; }
}

function parseEnv(text) {
  const out = {};
  for (const rawLine of text.split(/\r?\n/)) {
    const line = rawLine.trim();
    if (!line || line.startsWith('#')) continue;
    const idx = line.indexOf('=');
    if (idx < 0) continue;
    const key = line.slice(0, idx).trim();
    let value = line.slice(idx + 1).trim();
    if ((value.startsWith("'") && value.endsWith("'")) || (value.startsWith('"') && value.endsWith('"'))) {
      value = value.slice(1, -1);
    }
    value = value.replace(/\\'/g, "'");
    out[key] = value;
  }
  return out;
}

function rowsFromFile(file, expectedColumns) {
  const text = readText(file);
  if (!text) return [];
  return text.split(/\r?\n/).filter(Boolean).map((line) => {
    const parts = line.split('\t');
    while (parts.length < expectedColumns) parts.push('');
    return parts.slice(0, expectedColumns);
  });
}

function getPath(obj, path) {
  return path.split('.').reduce((current, key) => {
    if (current === null || current === undefined) return undefined;
    return current[key];
  }, obj);
}

function firstValue(obj, paths) {
  for (const item of paths) {
    const value = getPath(obj, item);
    if (value !== undefined && value !== null && String(value).trim() !== '') {
      return value;
    }
  }
  return '';
}

function escapeHtml(value) {
  return String(value)
    .replace(/&/g, '&amp;')
    .replace(/</g, '&lt;')
    .replace(/>/g, '&gt;')
    .replace(/"/g, '&quot;')
    .replace(/'/g, '&#39;');
}

function prettyValue(value, fallback = '-') {
  if (value === undefined || value === null || String(value).trim() === '') return fallback;
  return String(value);
}

function formatAmount(value) {
  if (value === undefined || value === null || String(value).trim() === '') return '-';
  const num = Number(value);
  if (Number.isFinite(num)) {
    return num.toFixed(2).replace(/\.00$/, '').replace(/(\.\d)0$/, '$1');
  }
  return String(value);
}

function pickOrderId(payload) {
  return firstValue(payload, ['order_no', 'order_sn', 'trade_no', 'out_trade_no', 'order_id', 'id']);
}

function loadBots() {
  return rowsFromFile(path.join(dataDir, 'bots.tsv'), 5).map(([id, name, token, enabled, created]) => ({
    id, name, token, enabled: enabled || 'yes', created
  }));
}

function loadNotifiers() {
  return rowsFromFile(path.join(dataDir, 'notifiers.tsv'), 7).map(([id, name, botId, chatId, type, enabled, created]) => ({
    id, name, botId, chatId, type, enabled: enabled || 'yes', created
  }));
}

function legacyFallback(settings) {
  if (settings.TG_BOT_TOKEN && settings.TG_CHAT_ID) {
    return [{
      key: 'legacy',
      botToken: settings.TG_BOT_TOKEN,
      chatId: settings.TG_CHAT_ID,
      name: 'legacy',
      botName: 'legacy'
    }];
  }
  return [];
}

function enabledRecipients(settings) {
  const bots = loadBots().filter((bot) => bot.enabled !== 'no');
  const botMap = new Map(bots.map((bot) => [bot.id, bot]));
  const seen = new Set();
  const recipients = [];

  for (const notifier of loadNotifiers()) {
    if (notifier.enabled === 'no') continue;
    const bot = botMap.get(notifier.botId);
    if (!bot || !bot.token || !notifier.chatId) continue;
    const key = `${bot.id}|${notifier.chatId}`;
    if (seen.has(key)) continue;
    seen.add(key);
    recipients.push({
      key,
      botToken: bot.token,
      chatId: notifier.chatId,
      name: notifier.name,
      botName: bot.name
    });
  }

  if (recipients.length > 0) return recipients;
  return legacyFallback(settings);
}

function buildMessage(payload) {
  const siteName = firstValue(payload, ['site_name', 'shop_name', 'app_name', 'system_name']) || '异次元发卡';
  const productName = firstValue(payload, ['product_name', 'goods_name', 'product_title', 'title', 'name', 'item_name']) || '商品购买通知';
  const orderNo = firstValue(payload, ['order_no', 'order_sn', 'trade_no', 'out_trade_no', 'order_id', 'id']);
  const status = firstValue(payload, ['pay_status', 'order_status', 'status', 'state']) || '已触发';
  const amount = firstValue(payload, ['pay_amount', 'total_amount', 'money', 'amount', 'price', 'total']);
  const payType = firstValue(payload, ['payment_method', 'pay_type', 'channel', 'payment', 'pay_channel']);
  const buyer = firstValue(payload, ['buyer', 'username', 'nickname', 'user_name', 'buyer_name', 'account']);
  const contact = [
    firstValue(payload, ['email']),
    firstValue(payload, ['phone']),
    firstValue(payload, ['mobile']),
    firstValue(payload, ['qq'])
  ].filter((item) => item && String(item).trim() !== '');
  const createTime = firstValue(payload, ['create_time', 'created_at', 'order_time', 'add_time', 'time']);
  const payTime = firstValue(payload, ['pay_time', 'paid_at', 'notify_time', 'success_time']);
  const notifyType = firstValue(payload, ['event_type', 'type', 'event']) || '商品购买';
  const note = firstValue(payload, ['remark', 'memo', 'note', 'message']);
  const orderUrl = firstValue(payload, ['order_url', 'url', 'detail_url']);
  const amountText = formatAmount(amount);
  const rawJson = JSON.stringify(payload, null, 2);
  const rawBlock = rawJson.length > 1200 ? `${rawJson.slice(0, 1200)}\n...` : rawJson;

  const lines = [
    `<b>${escapeHtml(siteName)} · ${escapeHtml(productName)}</b>`,
    `<b>通知类型：</b>${escapeHtml(notifyType)}`,
    `<b>订单状态：</b>${escapeHtml(status)}`,
    `<b>订单编号：</b><code>${escapeHtml(orderNo || '-')}</code>`,
    `<b>支付金额：</b>${escapeHtml(amountText)}`,
    `<b>支付方式：</b>${escapeHtml(payType || '-')}`,
    `<b>买家信息：</b>${escapeHtml(prettyValue(buyer))}`,
    `<b>联系方式：</b>${escapeHtml(contact.length ? contact.join(' / ') : '-')}`,
    `<b>下单时间：</b>${escapeHtml(prettyValue(createTime))}`,
    `<b>支付时间：</b>${escapeHtml(prettyValue(payTime))}`
  ];

  if (orderUrl) {
    lines.push(`<b>订单链接：</b><code>${escapeHtml(orderUrl)}</code>`);
  }
  if (note) {
    lines.push(`<b>备注：</b>${escapeHtml(note)}`);
  }

  lines.push('');
  lines.push('<b>原始数据</b>');
  lines.push(`<pre>${escapeHtml(rawBlock)}</pre>`);
  return lines.join('\n');
}

function buildNotifyHeader(payload) {
  const siteName = firstValue(payload, ['site_name', 'shop_name', 'app_name', 'system_name']) || '异次元发卡';
  const productName = firstValue(payload, ['product_name', 'goods_name', 'product_title', 'title', 'name', 'item_name']) || '商品购买通知';
  const orderId = pickOrderId(payload);
  return orderId ? `${siteName} · ${productName} · 订单 ${orderId}` : `${siteName} · ${productName}`;
}

async function sendTelegram(botToken, chatId, text) {
  const response = await fetch(`https://api.telegram.org/bot${botToken}/sendMessage`, {
    method: 'POST',
    headers: { 'Content-Type': 'application/json' },
    body: JSON.stringify({ chat_id: chatId, text, parse_mode: 'HTML', disable_web_page_preview: true })
  });
  if (!response.ok) {
    throw new Error(`Telegram API ${response.status}`);
  }
}

function readBody(req) {
  return new Promise((resolve, reject) => {
    const chunks = [];
    req.on('data', (chunk) => chunks.push(chunk));
    req.on('end', () => resolve(Buffer.concat(chunks).toString('utf8')));
    req.on('error', reject);
  });
}

function md5(text) {
  return crypto.createHash('md5').update(text).digest('hex');
}

const settings = parseEnv(readText(settingsPath));
const secretKey = settings.SECRET_KEY || process.env.SECRET_KEY || '';

const server = http.createServer(async (req, res) => {
  const url = new URL(req.url || '/', `http://${req.headers.host || '127.0.0.1'}`);

  if (req.method === 'GET' && url.pathname === '/health') {
    res.writeHead(200, { 'Content-Type': 'application/json; charset=utf-8' });
    res.end(JSON.stringify({
      ok: true,
      bots: loadBots().length,
      notifiers: loadNotifiers().length
    }));
    return;
  }

    if (req.method === 'POST' && url.pathname === '/webhook/notify') {
    try {
      const rawBody = await readBody(req);
      const payload = rawBody ? JSON.parse(rawBody) : {};
      const receivedSign = req.headers['x-signature'] || req.headers['sign'];

      if (receivedSign && secretKey) {
        const signatureOk = receivedSign === md5(`${rawBody}${secretKey}`) ||
          receivedSign === md5(`${JSON.stringify(payload)}${secretKey}`);
        if (!signatureOk) {
          res.writeHead(401, { 'Content-Type': 'application/json; charset=utf-8' });
          res.end(JSON.stringify({ msg: 'Invalid Signature' }));
          return;
        }
      }

      const recipients = enabledRecipients(settings);
      if (!recipients.length) {
        res.writeHead(503, { 'Content-Type': 'application/json; charset=utf-8' });
        res.end(JSON.stringify({ msg: 'No recipients configured' }));
        return;
      }

      const text = buildMessage(payload);
      const header = buildNotifyHeader(payload);
      let sent = 0;
      let failed = 0;
      await Promise.allSettled(recipients.map(async (item) => {
        await sendTelegram(item.botToken, item.chatId, `${header}\n\n${text}`);
        sent += 1;
      })).then((results) => {
        for (const result of results) {
          if (result.status === 'rejected') failed += 1;
        }
      });

      res.writeHead(failed === 0 ? 200 : 207, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ msg: 'OK', sent, failed }));
      return;
    } catch (error) {
      console.error('webhook error:', error);
      res.writeHead(500, { 'Content-Type': 'application/json; charset=utf-8' });
      res.end(JSON.stringify({ msg: 'Internal Server Error' }));
      return;
    }
  }

  res.writeHead(404, { 'Content-Type': 'application/json; charset=utf-8' });
  res.end(JSON.stringify({ msg: 'Not Found' }));
});

server.listen(port, () => {
  console.log(`TG Notify running on port ${port}`);
});
EOF

    cat > "${COMPOSE_FILE}" <<EOF
services:
  tg-notify:
    image: node:20-alpine
    container_name: tg-notify
    working_dir: /srv/app
    volumes:
      - ..:/srv
    environment:
      - TG_NOTIFY_DATA_DIR=/srv/data
      - TG_NOTIFY_SETTINGS_FILE=/srv/settings.env
      - PORT=${PORT}
    ports:
      - "${PORT}:${PORT}"
    command: node /srv/app/index.js
    restart: always
EOF
}

compose_cmd() {
    if docker compose version >/dev/null 2>&1; then
        printf 'docker compose'
    else
        printf 'docker-compose'
    fi
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
    (cd "${APP_DIR}" && ${cmd} up -d)
}

bot_name_by_id() {
    local wanted_id="$1"
    local id name token enabled created
    while IFS=$'\t' read -r id name token enabled created; do
        [[ "${id}" == "${wanted_id}" ]] && { printf '%s\n' "${name}"; return 0; }
    done < "${BOTS_DB}"
    printf '未知机器人(%s)\n' "${wanted_id}"
}

bot_token_by_id() {
    local wanted_id="$1"
    local id name token enabled created
    while IFS=$'\t' read -r id name token enabled created; do
        [[ "${id}" == "${wanted_id}" ]] && { printf '%s\n' "${token}"; return 0; }
    done < "${BOTS_DB}"
    return 1
}

list_bots() {
    ensure_base
    echo
    printf '%-4s %-6s %-18s %-24s %s\n' "序号" "状态" "名称" "Token" "创建时间"
    local seq=1 id name token enabled created
    while IFS=$'\t' read -r id name token enabled created; do
        [[ -n "${id}" ]] || continue
        printf '%-4s %-6s %-18s %-24s %s\n' "${seq}" "$(status_label "${enabled}")" "${name}" "$(short_token "${token}")" "${created}"
        seq=$((seq + 1))
    done < "${BOTS_DB}"
    [[ "${seq}" -eq 1 ]] && warn "还没有机器人。"
}

list_notifiers() {
    ensure_base
    echo
    printf '%-4s %-6s %-18s %-18s %-24s %-10s %s\n' "序号" "状态" "名称" "机器人" "Chat ID" "类型" "创建时间"
    local seq=1 id name bot_id chat_id type enabled created bot_name
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        [[ -n "${id}" ]] || continue
        bot_name="$(bot_name_by_id "${bot_id}")"
        printf '%-4s %-6s %-18s %-18s %-24s %-10s %s\n' "${seq}" "$(status_label "${enabled}")" "${name}" "${bot_name}" "${chat_id}" "${type}" "${created}"
        seq=$((seq + 1))
    done < "${NOTIFIERS_DB}"
    [[ "${seq}" -eq 1 ]] && warn "还没有通知位。"
}

select_bot_id() {
    local var_name="$1"
    local total seq selected_id
    total="$(row_count "${BOTS_DB}")"
    if [[ "${total}" -eq 0 ]]; then
        warn "还没有机器人，请先添加。"
        return 1
    fi
    list_bots
    while true; do
        seq="$(read_required "请选择机器人序号")"
        [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字。"; continue; }
        selected_id="$(get_id_by_seq "${BOTS_DB}" "${seq}")" || { warn "没有这个序号。"; continue; }
        printf -v "${var_name}" '%s' "${selected_id}"
        return 0
    done
}

select_notifier_id() {
    local var_name="$1"
    local total seq selected_id
    total="$(row_count "${NOTIFIERS_DB}")"
    if [[ "${total}" -eq 0 ]]; then
        warn "还没有通知位。"
        return 1
    fi
    list_notifiers
    while true; do
        seq="$(read_required "请选择通知位序号")"
        [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字。"; continue; }
        selected_id="$(get_id_by_seq "${NOTIFIERS_DB}" "${seq}")" || { warn "没有这个序号。"; continue; }
        printf -v "${var_name}" '%s' "${selected_id}"
        return 0
    done
}

add_bot() {
    ensure_base
    local name token enabled id created
    echo
    info "新增机器人"
    name="$(read_required "机器人名称")"
    token="$(read_required "Bot Token")"
    enabled="yes"
    if confirm "是否先停用这个机器人"; then
        enabled="no"
    fi
    id="$(next_id "${BOTS_DB}")"
    created="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${token}" "${enabled}" "${created}" >> "${BOTS_DB}"
    ok "机器人已添加。"
}

edit_bot() {
    ensure_base
    [[ -s "${BOTS_DB}" ]] || { warn "没有可修改的机器人。"; return 0; }
    list_bots
    local seq wanted_id tmp id name token enabled created new_name new_token new_enabled
    seq="$(read_required "请输入要修改的机器人序号")"
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字。"; return 1; }
    wanted_id="$(get_id_by_seq "${BOTS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }
    tmp="$(mktemp)"
    while IFS=$'\t' read -r id name token enabled created; do
        [[ -n "${id}" ]] || continue
        if [[ "${id}" == "${wanted_id}" ]]; then
            new_name="$(read_default "机器人名称" "${name}")"
            new_token="$(read_default "Bot Token" "${token}")"
            new_enabled="${enabled}"
            if confirm "是否切换启用状态"; then
                [[ "${enabled}" == "yes" ]] && new_enabled="no" || new_enabled="yes"
            fi
            printf '%s\t%s\t%s\t%s\t%s\n' "${id}" "${new_name}" "${new_token}" "${new_enabled}" "${created}" >> "${tmp}"
        else
            printf '%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${token}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${BOTS_DB}"
    mv "${tmp}" "${BOTS_DB}"
    ok "机器人已修改。"
}

delete_bot() {
    ensure_base
    [[ -s "${BOTS_DB}" ]] || { warn "没有可删除的机器人。"; return 0; }
    list_bots
    local seq wanted_id tmp id name token enabled created removed="no" notifier_tmp
    seq="$(read_required "请输入要删除的机器人序号")"
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字。"; return 1; }
    wanted_id="$(get_id_by_seq "${BOTS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }
    if ! confirm "删除机器人会连带删除它下面的通知位，继续吗"; then
        warn "已取消。"
        return 0
    fi
    tmp="$(mktemp)"
    while IFS=$'\t' read -r id name token enabled created; do
        [[ -n "${id}" ]] || continue
        if [[ "${id}" == "${wanted_id}" ]]; then
            removed="yes"
        else
            printf '%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${token}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${BOTS_DB}"
    mv "${tmp}" "${BOTS_DB}"

    notifier_tmp="$(mktemp)"
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        [[ -n "${id}" ]] || continue
        [[ "${bot_id}" == "${wanted_id}" ]] && continue
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "${enabled}" "${created}" >> "${notifier_tmp}"
    done < "${NOTIFIERS_DB}"
    mv "${notifier_tmp}" "${NOTIFIERS_DB}"
    [[ "${removed}" == "yes" ]] && ok "机器人已删除。"
}

toggle_bot() {
    ensure_base
    [[ -s "${BOTS_DB}" ]] || { warn "没有可切换的机器人。"; return 0; }
    list_bots
    local seq wanted_id tmp id name token enabled created new_enabled
    seq="$(read_required "请输入要切换状态的机器人序号")"
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字。"; return 1; }
    wanted_id="$(get_id_by_seq "${BOTS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }
    tmp="$(mktemp)"
    while IFS=$'\t' read -r id name token enabled created; do
        [[ -n "${id}" ]] || continue
        if [[ "${id}" == "${wanted_id}" ]]; then
            [[ "${enabled}" == "yes" ]] && new_enabled="no" || new_enabled="yes"
            printf '%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${token}" "${new_enabled}" "${created}" >> "${tmp}"
        else
            printf '%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${token}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${BOTS_DB}"
    mv "${tmp}" "${BOTS_DB}"
    ok "机器人状态已切换。"
}

test_bot() {
    ensure_base
    [[ -s "${BOTS_DB}" ]] || { warn "没有可测试的机器人。"; return 0; }
    list_bots
    local seq wanted_id token resp
    seq="$(read_required "请输入要测试的机器人序号")"
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字。"; return 1; }
    wanted_id="$(get_id_by_seq "${BOTS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }
    token="$(bot_token_by_id "${wanted_id}")" || { warn "获取 token 失败。"; return 1; }
    if resp="$(curl -fsS "https://api.telegram.org/bot${token}/getMe" 2>/dev/null)"; then
        ok "机器人 token 有效。"
        printf '%s\n' "${resp}"
    else
        err "机器人 token 无效或网络不可用。"
    fi
}

add_notifier() {
    ensure_base
    local name bot_id chat_id type_choice type enabled id created
    echo
    info "新增通知位"
    select_bot_id bot_id || return 1
    name="$(read_required "通知位名称，例如 admin、ops-group、notice-channel")"
    echo "类型:"
    echo "  1. 私聊/用户"
    echo "  2. 群组/超级群"
    echo "  3. 频道"
    while true; do
        type_choice="$(read_default "请选择" "1")"
        case "${type_choice}" in
            1) type="私聊"; break ;;
            2) type="群组"; break ;;
            3) type="频道"; break ;;
            *) warn "请输入 1、2 或 3。" ;;
        esac
    done
    chat_id="$(read_required "Chat ID 或 @频道用户名")"
    enabled="yes"
    if confirm "是否先停用这个通知位"; then
        enabled="no"
    fi
    id="$(next_id "${NOTIFIERS_DB}")"
    created="$(date '+%Y-%m-%d %H:%M:%S')"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "${enabled}" "${created}" >> "${NOTIFIERS_DB}"
    ok "通知位已添加。"
}

edit_notifier() {
    ensure_base
    [[ -s "${NOTIFIERS_DB}" ]] || { warn "没有可修改的通知位。"; return 0; }
    list_notifiers
    local seq wanted_id tmp id name bot_id chat_id type enabled created new_name new_bot_id new_chat_id new_type_choice new_type new_enabled
    seq="$(read_required "请输入要修改的通知位序号")"
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字。"; return 1; }
    wanted_id="$(get_id_by_seq "${NOTIFIERS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }
    tmp="$(mktemp)"
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        [[ -n "${id}" ]] || continue
        if [[ "${id}" == "${wanted_id}" ]]; then
            new_name="$(read_default "通知位名称" "${name}")"
            if confirm "是否更换机器人"; then
                select_bot_id new_bot_id || new_bot_id="${bot_id}"
            else
                new_bot_id="${bot_id}"
            fi
            new_chat_id="$(read_default "Chat ID 或 @频道用户名" "${chat_id}")"
            echo "类型:"
            echo "  1. 私聊/用户"
            echo "  2. 群组/超级群"
            echo "  3. 频道"
            case "${type}" in
                群组) new_type_choice="2" ;;
                频道) new_type_choice="3" ;;
                *) new_type_choice="1" ;;
            esac
            new_type_choice="$(read_default "请选择" "${new_type_choice}")"
            case "${new_type_choice}" in
                2) new_type="群组" ;;
                3) new_type="频道" ;;
                *) new_type="私聊" ;;
            esac
            new_enabled="${enabled}"
            if confirm "是否切换启用状态"; then
                [[ "${enabled}" == "yes" ]] && new_enabled="no" || new_enabled="yes"
            fi
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${new_name}" "${new_bot_id}" "${new_chat_id}" "${new_type}" "${new_enabled}" "${created}" >> "${tmp}"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${NOTIFIERS_DB}"
    mv "${tmp}" "${NOTIFIERS_DB}"
    ok "通知位已修改。"
}

delete_notifier() {
    ensure_base
    [[ -s "${NOTIFIERS_DB}" ]] || { warn "没有可删除的通知位。"; return 0; }
    list_notifiers
    local seq wanted_id tmp id name bot_id chat_id type enabled created removed="no"
    seq="$(read_required "请输入要删除的通知位序号")"
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字。"; return 1; }
    wanted_id="$(get_id_by_seq "${NOTIFIERS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }
    tmp="$(mktemp)"
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        [[ -n "${id}" ]] || continue
        if [[ "${id}" == "${wanted_id}" ]]; then
            removed="yes"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${NOTIFIERS_DB}"
    mv "${tmp}" "${NOTIFIERS_DB}"
    [[ "${removed}" == "yes" ]] && ok "通知位已删除。"
}

toggle_notifier() {
    ensure_base
    [[ -s "${NOTIFIERS_DB}" ]] || { warn "没有可切换的通知位。"; return 0; }
    list_notifiers
    local seq wanted_id tmp id name bot_id chat_id type enabled created new_enabled
    seq="$(read_required "请输入要切换状态的通知位序号")"
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字。"; return 1; }
    wanted_id="$(get_id_by_seq "${NOTIFIERS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }
    tmp="$(mktemp)"
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        [[ -n "${id}" ]] || continue
        if [[ "${id}" == "${wanted_id}" ]]; then
            [[ "${enabled}" == "yes" ]] && new_enabled="no" || new_enabled="yes"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "${new_enabled}" "${created}" >> "${tmp}"
        else
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "${id}" "${name}" "${bot_id}" "${chat_id}" "${type}" "${enabled}" "${created}" >> "${tmp}"
        fi
    done < "${NOTIFIERS_DB}"
    mv "${tmp}" "${NOTIFIERS_DB}"
    ok "通知位状态已切换。"
}

test_notifier() {
    ensure_base
    [[ -s "${NOTIFIERS_DB}" ]] || { warn "没有可测试的通知位。"; return 0; }
    list_notifiers
    local seq wanted_id id name bot_id chat_id type enabled created token text resp
    seq="$(read_required "请输入要测试的通知位序号")"
    [[ "${seq}" =~ ^[0-9]+$ ]] || { warn "请输入数字。"; return 1; }
    wanted_id="$(get_id_by_seq "${NOTIFIERS_DB}" "${seq}")" || { warn "没有这个序号。"; return 1; }
    while IFS=$'\t' read -r id name bot_id chat_id type enabled created; do
        [[ "${id}" == "${wanted_id}" ]] || continue
        token="$(bot_token_by_id "${bot_id}")" || { warn "找不到对应机器人。"; return 1; }
        text="TG Notify 测试消息
来源: ${name}
类型: ${type}
时间: $(date '+%Y-%m-%d %H:%M:%S')"
        if resp="$(curl -fsS -X POST "https://api.telegram.org/bot${token}/sendMessage" \
            --data-urlencode "chat_id=${chat_id}" \
            --data-urlencode "text=${text}" 2>/dev/null)"; then
            ok "测试消息已发送。"
            printf '%s\n' "${resp}"
            return 0
        fi
        err "发送失败，请检查 token、chat_id、群/频道权限和网络。"
        return 1
    done < "${NOTIFIERS_DB}"
}

edit_settings() {
    load_settings
    echo
    info "全局配置"
    SECRET_KEY="$(read_default "通信密钥 SECRET_KEY" "${SECRET_KEY:-secret-$(date +%s)}")"
    PORT="$(read_default "端口" "${PORT}")"
    UPDATE_URL="$(read_default "更新地址(可留空)" "${UPDATE_URL}")"
    INSTALL_URL="$(read_default "更新脚本地址" "${INSTALL_URL:-$DEFAULT_INSTALL_URL}")"
    WORK_DIR="$(read_default "工作目录(仅显示用)" "${WORK_DIR}")"
    save_settings
    ok "全局配置已保存。"
}

show_status() {
    load_settings
    local bots notifiers container_status
    bots="$(row_count "${BOTS_DB}")"
    notifiers="$(row_count "${NOTIFIERS_DB}")"
    if service_running; then
        container_status="运行中"
    elif [[ -f "${COMPOSE_FILE}" ]]; then
        container_status="已安装，未运行"
    else
        container_status="未安装"
    fi
    echo
    printf '配置目录: %s\n' "${BASE_DIR}"
    printf '工作目录: %s\n' "${WORK_DIR}"
    printf '端口: %s\n' "${PORT}"
  printf '机器人数量: %s\n' "${bots}"
  printf '通知位数量: %s\n' "${notifiers}"
  printf '容器状态: %s\n' "${container_status}"
  printf 'Webhook: %s/webhook/notify\n' "$(service_base_url)"
  printf '健康检查: %s/health\n' "$(service_base_url)"
}

bootstrap_defaults() {
    ensure_base
    if [[ "$(row_count "${BOTS_DB}")" -eq 0 ]]; then
        warn "还没有机器人，先补一个。"
        add_bot
    fi
    if [[ "$(row_count "${NOTIFIERS_DB}")" -eq 0 ]]; then
        warn "还没有通知位，先补一个。"
        add_notifier
    fi
}

do_install() {
    load_settings
    edit_settings
    bootstrap_defaults
    write_runtime
    compose_up
    date '+%Y-%m-%d %H:%M:%S' > "${RUNTIME_FLAG}"
    ok "已生成并启动。"
}

do_restart() {
    ensure_base
    [[ -f "${COMPOSE_FILE}" ]] || { warn "还没有部署。"; return 0; }
    compose_restart
    ok "已重启。"
}

do_stop() {
    ensure_base
    [[ -f "${COMPOSE_FILE}" ]] || { warn "还没有部署。"; return 0; }
    compose_down
    ok "已停止。"
}

do_update() {
    load_settings
    local tmp_dir backup_dir installer_url
    installer_url="${INSTALL_URL:-${DEFAULT_INSTALL_URL}}"
    tmp_dir="$(mktemp -d)"
    backup_dir="${tmp_dir}/backup"
    mkdir -p "${backup_dir}"

    cp -f "${SETTINGS_FILE}" "${backup_dir}/settings.env" 2>/dev/null || true
    cp -f "${BOTS_DB}" "${backup_dir}/bots.tsv" 2>/dev/null || true
    cp -f "${NOTIFIERS_DB}" "${backup_dir}/notifiers.tsv" 2>/dev/null || true

    info "正在下载更新脚本: ${installer_url}"
    if ! command -v curl >/dev/null 2>&1; then
        err "系统没有 curl，无法更新。"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if ! curl -fsSL "${installer_url}" -o "${tmp_dir}/install.sh"; then
        err "更新脚本下载失败。"
        rm -rf "${tmp_dir}"
        return 1
    fi

    if [[ ! -s "${tmp_dir}/install.sh" ]]; then
        err "下载到的脚本为空。"
        rm -rf "${tmp_dir}"
        return 1
    fi

    chmod +x "${tmp_dir}/install.sh" 2>/dev/null || true
    info "正在执行更新脚本。"
    if ! bash "${tmp_dir}/install.sh"; then
        err "远程安装脚本执行失败。"
        rm -rf "${tmp_dir}"
        return 1
    fi

    ensure_base
    cp -f "${backup_dir}/settings.env" "${SETTINGS_FILE}" 2>/dev/null || true
    cp -f "${backup_dir}/bots.tsv" "${BOTS_DB}" 2>/dev/null || true
    cp -f "${backup_dir}/notifiers.tsv" "${NOTIFIERS_DB}" 2>/dev/null || true

    write_runtime
    if [[ -f "${COMPOSE_FILE}" ]]; then
        compose_restart
    fi
    rm -rf "${tmp_dir}"
    ok "已完成更新，配置已保留。"
}

show_logs() {
    ensure_base
    [[ -f "${COMPOSE_FILE}" ]] || { warn "还没有部署。"; return 0; }
    local cmd
    cmd="$(compose_cmd)"
    (cd "${APP_DIR}" && ${cmd} logs -f --tail=100 tg-notify)
}

do_uninstall() {
    load_settings
    echo
    echo "将删除:"
    echo "1. 运行文件和容器编排"
    echo "2. 配置目录: ${BASE_DIR}"
    echo "3. 机器人和通知位数据"
    echo
    confirm "确认卸载删除吗" || { warn "已取消。"; return 0; }
    do_stop >/dev/null 2>&1 || true
    rm -f "${COMPOSE_FILE}" "${INDEX_FILE}" "${RUNTIME_FLAG}" "${SETTINGS_FILE}"
    rm -f "${BOTS_DB}" "${NOTIFIERS_DB}"
    rmdir "${APP_DIR}" 2>/dev/null || true
    rmdir "${DATA_DIR}" 2>/dev/null || true
    rmdir "${BASE_DIR}" 2>/dev/null || true
    ok "已卸载删除。"
}

bot_menu() {
    while true; do
        echo
        echo "========== 机器人管理 =========="
        echo "1. 新增机器人"
        echo "2. 查看机器人"
        echo "3. 修改机器人"
        echo "4. 删除机器人"
        echo "5. 启用/停用"
        echo "6. 测试 Token"
        echo "0. 返回"
        local choice
        read -r -p "请选择 [0-6]: " choice
        case "${choice}" in
            1) add_bot; pause_enter ;;
            2) list_bots; pause_enter ;;
            3) edit_bot; pause_enter ;;
            4) delete_bot; pause_enter ;;
            5) toggle_bot; pause_enter ;;
            6) test_bot; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选项。" ;;
        esac
    done
}

notifier_menu() {
    while true; do
        echo
        echo "========== 通知位管理 =========="
        echo "1. 新增通知位"
        echo "2. 查看通知位"
        echo "3. 修改通知位"
        echo "4. 删除通知位"
        echo "5. 启用/停用"
        echo "6. 测试发送"
        echo "0. 返回"
        local choice
        read -r -p "请选择 [0-6]: " choice
        case "${choice}" in
            1) add_notifier; pause_enter ;;
            2) list_notifiers; pause_enter ;;
            3) edit_notifier; pause_enter ;;
            4) delete_notifier; pause_enter ;;
            5) toggle_notifier; pause_enter ;;
            6) test_notifier; pause_enter ;;
            0) return 0 ;;
            *) warn "无效选项。" ;;
        esac
    done
}

main_menu() {
    while true; do
        echo
        echo "========== ${APP_NAME} =========="
        echo "1. 初始化/安装"
        echo "2. 机器人管理"
        echo "3. 通知位管理"
        echo "4. 修改全局配置"
        echo "5. 更新运行文件"
        echo "6. 重启"
        echo "7. 停止"
        echo "8. 查看状态"
        echo "9. 查看日志"
        echo "10. 卸载删除"
        echo "0. 退出"
        local choice
        read -r -p "请选择 [0-10]: " choice
        case "${choice}" in
            1) do_install; pause_enter ;;
            2) bot_menu ;;
            3) notifier_menu ;;
            4) edit_settings; pause_enter ;;
            5) do_update; pause_enter ;;
            6) do_restart; pause_enter ;;
            7) do_stop; pause_enter ;;
            8) show_status; pause_enter ;;
            9) show_logs ;;
            10) do_uninstall; pause_enter ;;
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
  bash tg-notify.sh settings
  bash tg-notify.sh bots
  bash tg-notify.sh notifiers
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
        settings|config) edit_settings ;;
        bots) bot_menu ;;
        notifiers) notifier_menu ;;
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
