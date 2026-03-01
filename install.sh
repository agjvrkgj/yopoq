#!/bin/bash
#
# SOOP VOD Downloader Bot - 一键管理脚本
# 支持: 安装 / 卸载 / 更新 / 添加 OneDrive 账号
#

set -e

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
NC='\033[0m'

INSTALL_DIR="/opt/soop-downloader"
SERVICE_NAME="soop-bot"
SERVICE_FILE="/etc/systemd/system/${SERVICE_NAME}.service"
REPO_URL="https://github.com/agjvrkgj/yopoq.git"
RAW_URL="https://raw.githubusercontent.com/agjvrkgj/yopoq/main"

print_banner() {
    echo -e "${CYAN}"
    echo "╔══════════════════════════════════════╗"
    echo "║   SOOP VOD Downloader Bot 🎬         ║"
    echo "║   自动下载 SOOP VOD → OneDrive       ║"
    echo "╚══════════════════════════════════════╝"
    echo -e "${NC}"
}

log_info()  { echo -e "${GREEN}[INFO]${NC} $1"; }
log_warn()  { echo -e "${YELLOW}[WARN]${NC} $1"; }
log_error() { echo -e "${RED}[ERROR]${NC} $1"; }

check_root() {
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户运行此脚本"
        exit 1
    fi
}

# ── 下载项目文件 ──────────────────────────────────────────

download_files() {
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${SCRIPT_DIR}/bot.py" ]; then
        cp "${SCRIPT_DIR}/bot.py" "${INSTALL_DIR}/"
        cp "${SCRIPT_DIR}/refresh_token.py" "${INSTALL_DIR}/"
        log_info "从本地复制项目文件"
    else
        TMP_DIR=$(mktemp -d)
        if git clone --depth 1 "$REPO_URL" "$TMP_DIR" 2>/dev/null; then
            cp "$TMP_DIR"/bot.py "${INSTALL_DIR}/"
            cp "$TMP_DIR"/refresh_token.py "${INSTALL_DIR}/"
            rm -rf "$TMP_DIR"
            log_info "从 GitHub 下载项目文件"
        else
            # Fallback to curl
            curl -fsSL "${RAW_URL}/bot.py" -o "${INSTALL_DIR}/bot.py" || { log_error "下载 bot.py 失败"; exit 1; }
            curl -fsSL "${RAW_URL}/refresh_token.py" -o "${INSTALL_DIR}/refresh_token.py" || { log_error "下载 refresh_token.py 失败"; exit 1; }
            [ -d "$TMP_DIR" ] && rm -rf "$TMP_DIR"
            log_info "从 GitHub (curl) 下载项目文件"
        fi
    fi
}

# ── 配置 Azure OneDrive ──────────────────────────────────

setup_azure_onedrive() {
    local REMOTE_NAME="$1"

    echo ""
    echo "配置方式："
    echo "  1. Azure App 自动配置（仅需租户ID、客户端ID、密钥）"
    echo "  2. Azure App + 账号密码配置（ROPC 模式）"
    echo "  3. 跳过，稍后手动运行 'rclone config'"
    echo ""
    read -p "选择配置方式 [1/2/3]: " azure_mode

    if [[ "$azure_mode" == "3" ]]; then
        log_warn "请稍后手动运行 'rclone config' 配置 OneDrive"
        return
    fi

    if [[ "$azure_mode" != "1" && "$azure_mode" != "2" ]]; then
        log_warn "无效选项，跳过配置"
        return
    fi

    echo ""
    echo -e "${YELLOW}以下信息在 Azure Portal (portal.azure.com) 获取：${NC}"
    echo -e "${YELLOW}Azure Portal → Azure Active Directory → 应用注册 → 你的应用${NC}"
    echo ""
    read -p "Azure 租户 ID (概述页面的 '目录(租户) ID'): " AZ_TENANT
    read -p "Azure 应用(客户端) ID (概述页面的 '应用程序(客户端) ID'): " AZ_CLIENT_ID
    read -p "Azure 客户端密钥 (证书和密钥 → 客户端密钥的 '值'): " AZ_CLIENT_SECRET

    local MS_USER=""
    local MS_PASS=""
    local DRIVE_USER_EMAIL=""

    if [[ "$azure_mode" == "2" ]]; then
        echo ""
        echo -e "${YELLOW}以下是你的 Microsoft 365 登录账号：${NC}"
        echo ""
        read -p "Microsoft 365 邮箱账号 (如 xxx@xxx.onmicrosoft.com): " MS_USER
        read -s -p "Microsoft 365 密码: " MS_PASS
        echo ""

        # Write azure config
        cat > "${INSTALL_DIR}/azure_config_${REMOTE_NAME}.json" << CFGEOF
{
    "tenant_id": "${AZ_TENANT}",
    "client_id": "${AZ_CLIENT_ID}",
    "client_secret": "${AZ_CLIENT_SECRET}",
    "username": "${MS_USER}",
    "password": "${MS_PASS}",
    "grant_mode": "ropc"
}
CFGEOF
    else
        echo ""
        read -p "OneDrive 用户邮箱 (上传到哪个用户的网盘): " DRIVE_USER_EMAIL

        cat > "${INSTALL_DIR}/azure_config_${REMOTE_NAME}.json" << CFGEOF
{
    "tenant_id": "${AZ_TENANT}",
    "client_id": "${AZ_CLIENT_ID}",
    "client_secret": "${AZ_CLIENT_SECRET}",
    "grant_mode": "client_credentials",
    "drive_user": "${DRIVE_USER_EMAIL}"
}
CFGEOF
    fi

    chmod 600 "${INSTALL_DIR}/azure_config_${REMOTE_NAME}.json"

    # For the first/default account, also save as azure_config.json
    if [[ "$REMOTE_NAME" == "onedrive" ]] || [[ ! -f "${INSTALL_DIR}/azure_config.json" ]]; then
        cp "${INSTALL_DIR}/azure_config_${REMOTE_NAME}.json" "${INSTALL_DIR}/azure_config.json"
    fi

    # Generate rclone config section for this remote
    log_info "正在获取 OneDrive token..."

    python3 << PYEOF
import requests, json, time, os

with open("${INSTALL_DIR}/azure_config_${REMOTE_NAME}.json") as f:
    cfg = json.load(f)

tenant = cfg["tenant_id"]
client_id = cfg["client_id"]
client_secret = cfg["client_secret"]
grant_mode = cfg.get("grant_mode", "client_credentials")

url = f"https://login.microsoftonline.com/{tenant}/oauth2/v2.0/token"

if grant_mode == "ropc":
    data = {
        "grant_type": "password",
        "client_id": client_id,
        "client_secret": client_secret,
        "scope": "https://graph.microsoft.com/.default offline_access",
        "username": cfg.get("username", ""),
        "password": cfg.get("password", ""),
    }
else:
    data = {
        "grant_type": "client_credentials",
        "client_id": client_id,
        "client_secret": client_secret,
        "scope": "https://graph.microsoft.com/.default",
    }

resp = requests.post(url, data=data)
token = resp.json()

if "access_token" not in token:
    print(f"[!] Token failed: {token.get('error_description', 'unknown')}")
    exit(1)

headers = {"Authorization": f"Bearer {token['access_token']}"}

if grant_mode == "ropc":
    drive_url = "https://graph.microsoft.com/v1.0/me/drive"
else:
    drive_user = cfg.get("drive_user", "")
    drive_url = f"https://graph.microsoft.com/v1.0/users/{drive_user}/drive"

drive_resp = requests.get(drive_url, headers=headers)
drive_info = drive_resp.json()

if "id" not in drive_info:
    print(f"[!] Drive error: {drive_info.get('error', {}).get('message', 'unknown')}")
    exit(1)

rclone_token = {
    "access_token": token["access_token"],
    "token_type": "Bearer",
    "refresh_token": token.get("refresh_token", ""),
    "expiry": time.strftime("%Y-%m-%dT%H:%M:%S.000000000+00:00",
                           time.gmtime(time.time() + token.get("expires_in", 3600))),
}

section = f"""
[${REMOTE_NAME}]
type = onedrive
client_id = {client_id}
client_secret = {client_secret}
drive_id = {drive_info['id']}
drive_type = {drive_info.get('driveType', 'business')}
token = {json.dumps(rclone_token)}
"""

conf_path = os.path.expanduser("~/.config/rclone/rclone.conf")
os.makedirs(os.path.dirname(conf_path), exist_ok=True)

# Read existing config, remove old section if exists
existing = ""
if os.path.exists(conf_path):
    with open(conf_path) as f:
        existing = f.read()

# Remove existing section for this remote
import re
pattern = rf"\[${REMOTE_NAME}\][^[]*"
existing = re.sub(pattern, "", existing).strip()

with open(conf_path, "w") as f:
    if existing:
        f.write(existing + "\n")
    f.write(section)

print(f"[*] ✅ rclone remote '${REMOTE_NAME}' configured")
PYEOF

    if [ $? -eq 0 ]; then
        log_info "OneDrive [${REMOTE_NAME}] 配置成功"
    else
        log_warn "OneDrive [${REMOTE_NAME}] 配置失败，请稍后手动配置"
    fi
}

# ── 卸载 ──────────────────────────────────────────────────

uninstall() {
    print_banner
    echo -e "${YELLOW}开始卸载 SOOP VOD Downloader Bot...${NC}\n"

    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "停止服务..."
        systemctl stop "$SERVICE_NAME"
    fi

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "禁用服务..."
        systemctl disable "$SERVICE_NAME"
    fi

    if [ -f "$SERVICE_FILE" ]; then
        log_info "删除 systemd 服务..."
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi

    if crontab -l 2>/dev/null | grep -q "refresh_token"; then
        log_info "删除 token 刷新 cron..."
        crontab -l 2>/dev/null | grep -v "refresh_token" | crontab - 2>/dev/null || true
    fi

    if [ -d "$INSTALL_DIR" ]; then
        echo ""
        read -p "是否删除安装目录 ${INSTALL_DIR}（包含下载的视频）？[y/N]: " del_dir
        if [[ "$del_dir" =~ ^[Yy]$ ]]; then
            rm -rf "$INSTALL_DIR"
            log_info "已删除 ${INSTALL_DIR}"
        else
            log_info "保留 ${INSTALL_DIR}"
        fi
    fi

    echo ""
    read -p "是否删除 rclone 配置（OneDrive 连接信息）？[y/N]: " del_rclone
    if [[ "$del_rclone" =~ ^[Yy]$ ]]; then
        rm -f /root/.config/rclone/rclone.conf
        log_info "已删除 rclone 配置"
    fi

    echo ""
    log_info "✅ 卸载完成！"
}

# ── 更新 ──────────────────────────────────────────────────

update() {
    print_banner
    check_root
    echo -e "${GREEN}开始更新 SOOP VOD Downloader Bot...${NC}\n"

    if [ ! -d "$INSTALL_DIR" ]; then
        log_error "未检测到安装，请先执行安装"
        exit 1
    fi

    # Backup config
    log_info "备份配置文件..."
    [ -f "${INSTALL_DIR}/config.py" ] && cp "${INSTALL_DIR}/config.py" "${INSTALL_DIR}/config.py.bak"
    [ -f "${INSTALL_DIR}/azure_config.json" ] && cp "${INSTALL_DIR}/azure_config.json" "${INSTALL_DIR}/azure_config.json.bak"

    # Download latest files
    log_info "下载最新版本..."
    download_files

    # Restore config
    [ -f "${INSTALL_DIR}/config.py.bak" ] && mv "${INSTALL_DIR}/config.py.bak" "${INSTALL_DIR}/config.py"
    [ -f "${INSTALL_DIR}/azure_config.json.bak" ] && mv "${INSTALL_DIR}/azure_config.json.bak" "${INSTALL_DIR}/azure_config.json"

    # Update dependencies
    log_info "更新 Python 依赖..."
    pip3 install --break-system-packages -q --upgrade yt-dlp python-telegram-bot requests 2>/dev/null || \
    pip3 install -q --upgrade yt-dlp python-telegram-bot requests

    # Restart service
    systemctl restart "$SERVICE_NAME"

    echo ""
    log_info "✅ 更新完成！配置文件已保留。"
    echo ""

    # Show version
    echo "  yt-dlp 版本: $(yt-dlp --version 2>/dev/null || echo '未知')"
    echo "  服务状态: $(systemctl is-active $SERVICE_NAME)"
    echo ""
}

# ── 添加 OneDrive 账号 ───────────────────────────────────

add_onedrive() {
    print_banner
    check_root
    echo -e "${GREEN}添加 OneDrive 账号${NC}\n"

    if [ ! -d "$INSTALL_DIR" ]; then
        log_error "未检测到安装，请先执行安装"
        exit 1
    fi

    # Show existing accounts
    echo -e "${CYAN}当前已配置的 rclone remotes:${NC}"
    rclone listremotes 2>/dev/null || echo "  (无)"
    echo ""

    # Get new account info
    read -p "新账号的 rclone remote 名称 (如 onedrive2): " NEW_REMOTE
    if [ -z "$NEW_REMOTE" ]; then
        log_error "名称不能为空"
        exit 1
    fi

    read -p "OneDrive 目标文件夹 [SOOP_VOD]: " NEW_DEST
    NEW_DEST=${NEW_DEST:-SOOP_VOD}

    # Setup Azure for this remote
    setup_azure_onedrive "$NEW_REMOTE"

    # Read display name
    read -p "账号显示名称 (在 Bot 中显示，如 '备用网盘'，回车用 ${NEW_REMOTE}): " DISPLAY_NAME
    DISPLAY_NAME=${DISPLAY_NAME:-$NEW_REMOTE}

    # Update config.py - add to ONEDRIVE_ACCOUNTS
    if [ -f "${INSTALL_DIR}/config.py" ]; then
        # Check if ONEDRIVE_ACCOUNTS exists
        if grep -q "ONEDRIVE_ACCOUNTS" "${INSTALL_DIR}/config.py"; then
            # Add new account before the closing brace
            python3 << PYEOF
import re

with open("${INSTALL_DIR}/config.py") as f:
    content = f.read()

# Find ONEDRIVE_ACCOUNTS dict and add new entry
new_entry = '    "${DISPLAY_NAME}": {"remote": "${NEW_REMOTE}", "dest": "${NEW_DEST}"},'
pattern = r'(ONEDRIVE_ACCOUNTS\s*=\s*\{[^}]*)'
match = re.search(pattern, content, re.DOTALL)
if match:
    insert_pos = match.end()
    content = content[:insert_pos] + "\n" + new_entry + content[insert_pos:]

with open("${INSTALL_DIR}/config.py", "w") as f:
    f.write(content)

print("Config updated")
PYEOF
            log_info "已添加到 config.py"
        else
            log_warn "config.py 格式不兼容，请手动添加"
        fi
    fi

    # Restart bot
    systemctl restart "$SERVICE_NAME" 2>/dev/null || true

    echo ""
    log_info "✅ OneDrive 账号 [${DISPLAY_NAME}] 添加完成！"
    echo ""
    echo "  Remote 名称: ${NEW_REMOTE}"
    echo "  目标文件夹: ${NEW_DEST}"
    echo "  显示名称: ${DISPLAY_NAME}"
    echo ""
    echo "  在 Bot 中使用 /switch 切换账号"
    echo "  使用 /accounts 查看所有账号"
    echo ""
}

# ── 安装 ──────────────────────────────────────────────────

install() {
    print_banner
    check_root
    echo -e "${GREEN}开始安装 SOOP VOD Downloader Bot...${NC}\n"

    if ! command -v apt-get &>/dev/null; then
        log_error "仅支持 Debian/Ubuntu 系统"
        exit 1
    fi

    # ── 1. 安装系统依赖 ──
    log_info "安装系统依赖..."
    apt-get update -qq
    apt-get install -y -qq python3 python3-pip ffmpeg aria2 curl git > /dev/null 2>&1
    log_info "系统依赖安装完成"

    # ── 2. 安装 Python 依赖 ──
    log_info "安装 Python 依赖..."
    pip3 install --break-system-packages -q yt-dlp python-telegram-bot requests pyotp msal 2>/dev/null || \
    pip3 install -q yt-dlp python-telegram-bot requests pyotp msal
    log_info "Python 依赖安装完成"

    # ── 3. 安装 rclone ──
    if ! command -v rclone &>/dev/null; then
        log_info "安装 rclone..."
        curl -s https://rclone.org/install.sh | bash > /dev/null 2>&1
        log_info "rclone 安装完成"
    else
        log_info "rclone 已安装"
    fi

    # ── 4. 创建安装目录 ──
    mkdir -p "${INSTALL_DIR}"/{downloads,logs}

    # ── 5. 获取项目文件 ──
    log_info "下载项目文件..."
    download_files

    # ── 6. 交互式配置 ──
    echo ""
    echo -e "${CYAN}═══ 配置信息 ═══${NC}"
    echo ""

    # Telegram Bot Token
    if [ -f "${INSTALL_DIR}/config.py" ]; then
        EXISTING_TOKEN=$(grep "TG_TOKEN" "${INSTALL_DIR}/config.py" | cut -d'"' -f2)
        read -p "Telegram Bot Token [${EXISTING_TOKEN:0:10}...]: " TG_TOKEN
        TG_TOKEN=${TG_TOKEN:-$EXISTING_TOKEN}
    else
        read -p "Telegram Bot Token (从 @BotFather 获取): " TG_TOKEN
    fi

    if [ -z "$TG_TOKEN" ]; then
        log_error "Bot Token 不能为空"
        exit 1
    fi

    # Admin ID
    if [ -f "${INSTALL_DIR}/config.py" ]; then
        EXISTING_ADMIN=$(grep "ADMIN_ID" "${INSTALL_DIR}/config.py" | grep -o '[0-9]*')
        read -p "Telegram 管理员 ID [${EXISTING_ADMIN}]: " ADMIN_ID
        ADMIN_ID=${ADMIN_ID:-$EXISTING_ADMIN}
    else
        read -p "Telegram 管理员 ID: " ADMIN_ID
    fi

    if [ -z "$ADMIN_ID" ]; then
        log_error "管理员 ID 不能为空"
        exit 1
    fi

    # SOOP Account
    echo ""
    read -p "SOOP 用户名 (可选，用于 19 禁内容，回车跳过): " SOOP_USER
    if [ -n "$SOOP_USER" ]; then
        read -p "SOOP 密码: " SOOP_PASS
    else
        SOOP_USER=""
        SOOP_PASS=""
    fi

    # OneDrive rclone remote
    echo ""
    read -p "rclone OneDrive remote 名称 [onedrive]: " RCLONE_REMOTE
    RCLONE_REMOTE=${RCLONE_REMOTE:-onedrive}

    read -p "OneDrive 目标文件夹 [SOOP_VOD]: " RCLONE_DEST
    RCLONE_DEST=${RCLONE_DEST:-SOOP_VOD}

    # ── 7. 生成配置文件 ──
    cat > "${INSTALL_DIR}/config.py" << PYEOF
"""Configuration for SOOP VOD Downloader Bot"""

# Telegram
TG_TOKEN = "${TG_TOKEN}"
ADMIN_ID = ${ADMIN_ID}

# Paths
DOWNLOAD_DIR = "${INSTALL_DIR}/downloads"
LOG_DIR = "${INSTALL_DIR}/logs"

# Rclone - Multiple OneDrive accounts
ONEDRIVE_ACCOUNTS = {
    "${RCLONE_REMOTE}": {"remote": "${RCLONE_REMOTE}", "dest": "${RCLONE_DEST}"},
}
DEFAULT_ONEDRIVE = "${RCLONE_REMOTE}"

# yt-dlp
YTDLP_FORMAT = "best"

# SOOP Account (for age-restricted content)
SOOP_USERNAME = "${SOOP_USER}"
SOOP_PASSWORD = "${SOOP_PASS}"
PYEOF

    log_info "配置文件已生成"

    # ── 8. OneDrive 配置 ──
    echo ""
    echo -e "${CYAN}═══ OneDrive 配置 ═══${NC}"

    if ! rclone about "${RCLONE_REMOTE}:" > /dev/null 2>&1; then
        setup_azure_onedrive "$RCLONE_REMOTE"
    else
        log_info "rclone OneDrive 已配置"
    fi

    # ── 9. 安装 systemd 服务 ──
    cat > "$SERVICE_FILE" << EOF
[Unit]
Description=SOOP VOD Downloader Telegram Bot
After=network.target

[Service]
Type=simple
WorkingDirectory=${INSTALL_DIR}
ExecStart=/usr/bin/python3 ${INSTALL_DIR}/bot.py
Restart=always
RestartSec=10
Environment=PYTHONUNBUFFERED=1

[Install]
WantedBy=multi-user.target
EOF

    systemctl daemon-reload
    systemctl enable "$SERVICE_NAME" > /dev/null 2>&1
    systemctl restart "$SERVICE_NAME"

    log_info "Bot 服务已启动"

    # ── 10. Token 刷新 cron ──
    if [ -f "${INSTALL_DIR}/refresh_token.py" ]; then
        (crontab -l 2>/dev/null | grep -v refresh_token; echo "0 * * * * /usr/bin/python3 ${INSTALL_DIR}/refresh_token.py >> ${INSTALL_DIR}/logs/token_refresh.log 2>&1") | crontab -
        log_info "Token 自动刷新已配置（每小时）"
    fi

    # ── 完成 ──
    echo ""
    echo -e "${GREEN}╔══════════════════════════════════════╗${NC}"
    echo -e "${GREEN}║   ✅ 安装完成！                      ║${NC}"
    echo -e "${GREEN}╚══════════════════════════════════════╝${NC}"
    echo ""
    echo "  安装目录: ${INSTALL_DIR}"
    echo "  服务状态: systemctl status ${SERVICE_NAME}"
    echo "  查看日志: journalctl -u ${SERVICE_NAME} -f"
    echo ""
    echo "  管理命令:"
    echo "    systemctl start ${SERVICE_NAME}     # 启动"
    echo "    systemctl stop ${SERVICE_NAME}      # 停止"
    echo "    systemctl restart ${SERVICE_NAME}   # 重启"
    echo ""
}

# ── 入口 ──────────────────────────────────────────────────

case "${1:-}" in
    install)
        install
        ;;
    uninstall|remove|delete)
        uninstall
        ;;
    update|upgrade)
        update
        ;;
    add-onedrive|add_onedrive)
        add_onedrive
        ;;
    *)
        print_banner
        echo "请选择操作:"
        echo ""
        echo "  1) 安装"
        echo "  2) 更新"
        echo "  3) 添加 OneDrive 账号"
        echo "  4) 卸载"
        echo ""
        read -p "输入选项 [1/2/3/4]: " choice
        case "$choice" in
            1) install ;;
            2) update ;;
            3) add_onedrive ;;
            4) uninstall ;;
            *) echo "无效选项"; exit 1 ;;
        esac
        ;;
esac
