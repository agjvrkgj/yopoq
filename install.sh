#!/bin/bash
#
# SOOP VOD Downloader Bot - 一键安装/卸载脚本
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

# ── 卸载 ──────────────────────────────────────────────────

uninstall() {
    print_banner
    echo -e "${YELLOW}开始卸载 SOOP VOD Downloader Bot...${NC}\n"

    # 停止服务
    if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "停止服务..."
        systemctl stop "$SERVICE_NAME"
    fi

    if systemctl is-enabled --quiet "$SERVICE_NAME" 2>/dev/null; then
        log_info "禁用服务..."
        systemctl disable "$SERVICE_NAME"
    fi

    # 删除服务文件
    if [ -f "$SERVICE_FILE" ]; then
        log_info "删除 systemd 服务..."
        rm -f "$SERVICE_FILE"
        systemctl daemon-reload
    fi

    # 删除 crontab
    if crontab -l 2>/dev/null | grep -q "refresh_token"; then
        log_info "删除 token 刷新 cron..."
        crontab -l 2>/dev/null | grep -v "refresh_token" | crontab - 2>/dev/null || true
    fi

    # 删除安装目录
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

    # 删除 rclone 配置
    echo ""
    read -p "是否删除 rclone 配置（OneDrive 连接信息）？[y/N]: " del_rclone
    if [[ "$del_rclone" =~ ^[Yy]$ ]]; then
        rm -f /root/.config/rclone/rclone.conf
        log_info "已删除 rclone 配置"
    fi

    echo ""
    log_info "✅ 卸载完成！"
    echo ""
    echo "以下依赖未卸载（可能被其他程序使用）："
    echo "  - python3, yt-dlp, ffmpeg, aria2c, rclone"
    echo "  如需卸载请手动执行："
    echo "    pip3 uninstall yt-dlp"
    echo "    apt remove ffmpeg aria2"
    echo "    rclone 卸载参考: https://rclone.org/uninstall/"
}

# ── 安装 ──────────────────────────────────────────────────

install() {
    print_banner
    echo -e "${GREEN}开始安装 SOOP VOD Downloader Bot...${NC}\n"

    # 检查 root
    if [ "$EUID" -ne 0 ]; then
        log_error "请使用 root 用户运行此脚本"
        exit 1
    fi

    # 检查系统
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

    # 如果是从 git clone 运行的，复制本地文件
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    if [ -f "${SCRIPT_DIR}/bot.py" ]; then
        cp "${SCRIPT_DIR}/bot.py" "${INSTALL_DIR}/"
        cp "${SCRIPT_DIR}/refresh_token.py" "${INSTALL_DIR}/"
        log_info "从本地复制项目文件"
    else
        # 从 GitHub 下载
        TMP_DIR=$(mktemp -d)
        git clone --depth 1 "$REPO_URL" "$TMP_DIR" 2>/dev/null || {
            log_error "无法从 GitHub 下载，请检查网络连接"
            exit 1
        }
        cp "$TMP_DIR"/bot.py "${INSTALL_DIR}/"
        cp "$TMP_DIR"/refresh_token.py "${INSTALL_DIR}/"
        rm -rf "$TMP_DIR"
        log_info "从 GitHub 下载项目文件"
    fi

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

# Rclone
RCLONE_REMOTE = "${RCLONE_REMOTE}"
RCLONE_DEST = "${RCLONE_DEST}"

# yt-dlp
YTDLP_FORMAT = "best"

# SOOP Account (for age-restricted content)
SOOP_USERNAME = "${SOOP_USER}"
SOOP_PASSWORD = "${SOOP_PASS}"
PYEOF

    log_info "配置文件已生成"

    # ── 8. 生成 refresh_token.py（如果有 Azure 配置） ──
    echo ""
    echo -e "${CYAN}═══ OneDrive 配置 ═══${NC}"
    echo ""
    echo "OneDrive 需要通过 rclone 配置。"
    echo ""

    if ! rclone about "${RCLONE_REMOTE}:" > /dev/null 2>&1; then
        echo "rclone 尚未配置 OneDrive。"
        echo ""
        echo "两种配置方式："
        echo "  1. 手动运行 'rclone config' 配置 OneDrive"
        echo "  2. 使用 Azure App 凭据自动配置"
        echo ""
        read -p "是否现在配置 Azure App 自动连接？[y/N]: " setup_azure
        if [[ "$setup_azure" =~ ^[Yy]$ ]]; then
            echo ""
            echo -e "${YELLOW}以下信息在 Azure Portal (portal.azure.com) 获取：${NC}"
            echo -e "${YELLOW}Azure Portal → Azure Active Directory → 应用注册 → 你的应用${NC}"
            echo ""
            read -p "Azure 租户 ID (概述页面的 '目录(租户) ID'): " AZ_TENANT
            read -p "Azure 应用(客户端) ID (概述页面的 '应用程序(客户端) ID'): " AZ_CLIENT_ID
            read -p "Azure 客户端密钥 (证书和密钥 → 客户端密钥的 '值'): " AZ_CLIENT_SECRET
            echo ""
            echo -e "${YELLOW}以下是你的 Microsoft 365 登录账号：${NC}"
            echo ""
            read -p "Microsoft 365 邮箱账号 (如 xxx@xxx.onmicrosoft.com): " MS_USER
            read -s -p "Microsoft 365 密码: " MS_PASS
            echo ""

            cat > "${INSTALL_DIR}/refresh_token.py" << PYEOF
#!/usr/bin/env python3
"""Refresh rclone OneDrive token via ROPC."""
import requests, json, time

TENANT_ID = "${AZ_TENANT}"
CLIENT_ID = "${AZ_CLIENT_ID}"
CLIENT_SECRET = "${AZ_CLIENT_SECRET}"
USERNAME = "${MS_USER}"
PASSWORD = "${MS_PASS}"
RCLONE_CONF = "/root/.config/rclone/rclone.conf"

def refresh_token():
    url = f"https://login.microsoftonline.com/{TENANT_ID}/oauth2/v2.0/token"
    data = {
        "grant_type": "password",
        "client_id": CLIENT_ID,
        "client_secret": CLIENT_SECRET,
        "scope": "https://graph.microsoft.com/.default offline_access",
        "username": USERNAME,
        "password": PASSWORD,
    }
    resp = requests.post(url, data=data)
    token = resp.json()
    if "access_token" not in token:
        print(f"[!] Token refresh failed: {token.get('error_description', 'unknown')}")
        return False

    headers = {"Authorization": f"Bearer {token['access_token']}"}
    drive_resp = requests.get("https://graph.microsoft.com/v1.0/me/drive", headers=headers)
    drive_info = drive_resp.json()
    drive_id = drive_info.get("id", "")
    drive_type = drive_info.get("driveType", "business")

    rclone_token = {
        "access_token": token["access_token"],
        "token_type": token.get("token_type", "Bearer"),
        "refresh_token": token.get("refresh_token", ""),
        "expiry": time.strftime("%Y-%m-%dT%H:%M:%S.000000000+00:00",
                               time.gmtime(time.time() + token.get("expires_in", 3600))),
    }

    config = f"""[onedrive]
type = onedrive
client_id = {CLIENT_ID}
client_secret = {CLIENT_SECRET}
drive_id = {drive_id}
drive_type = {drive_type}
token = {json.dumps(rclone_token)}
"""
    import os
    os.makedirs(os.path.dirname(RCLONE_CONF), exist_ok=True)
    with open(RCLONE_CONF, "w") as f:
        f.write(config)
    print(f"[*] Token refreshed, expires in {token.get('expires_in', '?')}s")
    return True

if __name__ == "__main__":
    if refresh_token():
        print("[*] ✅ Token refresh successful")
    else:
        print("[!] ❌ Token refresh failed")
        exit(1)
PYEOF

            log_info "正在获取 OneDrive token..."
            python3 "${INSTALL_DIR}/refresh_token.py" && log_info "OneDrive 配置成功" || log_warn "OneDrive 配置失败，请稍后手动配置"
        else
            log_warn "请稍后手动运行 'rclone config' 配置 OneDrive"
        fi
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
    echo "  卸载: bash install.sh uninstall"
    echo ""
}

# ── 入口 ──────────────────────────────────────────────────

case "${1:-}" in
    uninstall|remove|delete)
        uninstall
        ;;
    *)
        install
        ;;
esac
